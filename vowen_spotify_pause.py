#!/usr/bin/env python3
"""Pause Spotify while Vowen is dictating, resume when it stops.

Lifecycle is tied to Vowen: launchd starts this when Vowen writes its
cli/server.json, and the loop exits as soon as Vowen's process is gone, so
nothing lingers once the app is closed.

Polls Vowen's local CLI API for the `recording` flag over a single reused
keep-alive connection, and drives Spotify over AppleScript. Only resumes
playback it paused itself, so it never starts music you stopped on purpose.
"""

import http.client
import json
import os
import subprocess
import sys
import time
from pathlib import Path

SERVER_JSON = Path.home() / "Library/Application Support/Vowen/cli/server.json"
STATUS_PATH = "/v1/status"
POLL_SECONDS = 0.12
RETRY_SECONDS = 0.5

# Checks and pauses in one AppleScript round trip to keep dictation latency low.
PAUSE_IF_PLAYING = '''
if application "Spotify" is running then
    tell application "Spotify"
        if player state is playing then
            pause
            return "paused"
        end if
    end tell
end if
return "no"
'''

RESUME = 'if application "Spotify" is running then tell application "Spotify" to play'


def log(message):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)


def osascript(script):
    try:
        result = subprocess.run(
            ["osascript", "-e", script], capture_output=True, text=True, timeout=10
        )
    except subprocess.TimeoutExpired:
        log("osascript timed out")
        return ""
    if result.returncode != 0:
        log(f"osascript failed: {result.stderr.strip()}")
        return ""
    return result.stdout.strip()


def process_is_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def connect():
    """Opens a keep-alive connection to Vowen. None means Vowen is down."""
    try:
        config = json.loads(SERVER_JSON.read_text())
        port, token, pid = config["port"], config["token"], config["pid"]
    except (OSError, ValueError, KeyError):
        return None
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    headers = {"Authorization": f"Bearer {token}", "Connection": "keep-alive"}
    return connection, headers, pid


def main():
    session = connect()
    if session is None:
        log("Vowen is not running, nothing to watch")
        return
    connection, headers, pid = session

    paused_by_us = False
    was_recording = False
    log(f"watching Vowen (pid {pid}) for dictation")

    while True:
        stale = False
        try:
            connection.request("GET", STATUS_PATH, headers=headers)
            response = connection.getresponse()
            body = response.read()
            # The token rotates on every app start.
            stale = response.status == 401
            if not stale and response.status != 200:
                time.sleep(RETRY_SECONDS)
                continue
        except (OSError, http.client.HTTPException):
            stale = True
            time.sleep(RETRY_SECONDS)

        if stale:
            connection.close()
            if not process_is_alive(pid):
                break
            session = connect()
            if session is None:
                break
            connection, headers, pid = session
            continue

        recording = json.loads(body)["recording"]

        if recording and not was_recording:
            if osascript(PAUSE_IF_PLAYING) == "paused":
                paused_by_us = True
                log("dictation started, Spotify paused")
        elif was_recording and not recording:
            if paused_by_us:
                osascript(RESUME)
                paused_by_us = False
                log("dictation ended, Spotify resumed")

        was_recording = recording
        time.sleep(POLL_SECONDS)

    # Vowen quit. Never leave Spotify stranded in a pause we caused.
    if paused_by_us:
        log("Vowen quit mid-dictation, resuming Spotify")
        osascript(RESUME)
    log("Vowen closed, exiting")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
