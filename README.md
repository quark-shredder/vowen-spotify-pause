# vowen-spotify-pause

Pauses Spotify the moment a [Vowen](https://vowen.ai) dictation starts and resumes it when the dictation ends. Runs only while Vowen runs.

Vowen has this built in (`pauseDuringRecording`) but gates it behind the Pro plan. This reproduces it externally without touching Vowen.

## How it works

Nothing polls. The process sleeps in its run loop until something happens.

| Edge | Source |
|---|---|
| Dictation start / end | CoreAudio property listener on the default input device (`kAudioDevicePropertyDeviceIsRunningSomewhere`) — Vowen's recorder only runs the mic while dictating |
| "Is this Vowen, not Zoom?" | One `GET /v1/status` to Vowen's local CLI API per start edge, token from `~/Library/Application Support/Vowen/cli/server.json` |
| Vowen quit | kqueue `NOTE_EXIT` on Vowen's pid → process exits |
| Vowen launch | launchd `WatchPaths` on Vowen's `cli/` directory → process starts |
| Spotify pause / play | Raw Apple Events (`spfy`/`Paus`, `spfy`/`Play`, property `pPlS`), addressed by pid so Spotify is never launched |

Only resumes playback it paused itself.

## Measured (macOS, Apple Silicon)

| | Idle CPU | Wakeups / s | Private memory | Pause latency |
|---|---|---|---|---|
| Python poller, `urllib` | ~1.1 % core | 8.3 | 10.0 MB | ~245 ms |
| Python poller, keep-alive | ~0.5 % core | 8.3 | 10.0 MB | ~245 ms |
| Swift, `NSAppleScript` | 0 | 0 | 21.8 MB | 30–130 ms |
| **Swift, raw Apple Events** | **0** | **0** | **3.8 MB** | **~40 ms** |

## Install

```sh
./install.sh            # build, codesign, install to ~/.local/bin, load LaunchAgent
./install.sh uninstall
```

macOS will ask once to allow `vowen-spotify-pause` to control Spotify (Automation permission). Log: `~/Library/Logs/vowen-spotify-pause.log`.

```sh
~/.local/bin/vowen-spotify-pause --check   # Spotify state + Apple Event round trip, no side effects
```

## Known limits

- If another app already holds the mic when a dictation starts (e.g. you dictate during a Zoom call), no start edge fires and music is not paused.
- Ad-hoc code signature: rebuilding may re-trigger the Automation permission prompt.
