# Decisions

1. **2026-09-03 — Don't modify Vowen.** Pause-during-dictation exists in Vowen but is Pro-gated, and the app is closed source. Build it externally instead of touching the gate.
2. **2026-09-04 — First version: poll Vowen's local API.** `GET /v1/status` exposes a `recording` flag; poll it at 120 ms from Python. Works, ~1 % core.
3. **2026-09-05 — Event-driven, not polling.** Measured: the request cost 73 µs but the daemon burned ~0.5 % core — the 8.3 wakeups/s were the cost, not the work. Switched to a CoreAudio `DeviceIsRunningSomewhere` listener (verified idle = false with Vowen running). The API is kept for one confirmation per start edge.
4. **2026-09-05 — Lifecycle tied to Vowen.** launchd `WatchPaths` on Vowen's `cli/` dir starts it; kqueue `NOTE_EXIT` on Vowen's pid ends it. No always-on agent.
5. **2026-09-05 — Raw Apple Events for Spotify.** `NSAppleScript` cost 21.8 MB just to compile two scripts; `osascript` spawn cost 125 ms per edge. Hand-built events from `sdef Spotify.app` give 3.8 MB and ~35 ms.
6. **2026-09-05 — No ticket key on commits.** Personal project; owner's call.
