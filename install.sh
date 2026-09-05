#!/bin/bash
# Build, install and start the agent.  ./install.sh uninstall  removes it again.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=local.vowen-spotify-pause
BIN="$HOME/.local/bin/vowen-spotify-pause"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = uninstall ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$BIN"
    echo "removed $LABEL"
    exit 0
fi

mkdir -p build "$(dirname "$BIN")" "$(dirname "$PLIST")"
swiftc -O vowen-spotify-pause.swift -o build/vowen-spotify-pause
# Stable ad-hoc identity so the Automation (Spotify) permission survives rebuilds.
codesign -s - -f -i "$LABEL" build/vowen-spotify-pause
install -m 755 build/vowen-spotify-pause "$BIN"
sed "s|@HOME@|$HOME|g" "$LABEL.plist" > "$PLIST"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout is asynchronous; bootstrapping while the old job tears down fails with EIO.
for _ in $(seq 20); do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.25; done
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed $BIN and loaded $LABEL"
