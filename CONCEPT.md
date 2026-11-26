# oton: Concept & Decisions

Status: rewrite from Continuum, 2026-11-26. Personal tool, single user. UI, CLI and docs in English; the Gemini prompt is German.

## Problem

We record meetings, transcribe them and have an LLM pull out the tasks. The predecessor, **Continuum**, kept a rolling 4-hour buffer on the office network so a forgotten meeting could be saved afterwards. **Dropped 2026-11-26:** an always-on recording window isn't acceptable. oton records only when I start it.

## Flow

```
left click / ot start ──▶ record (preferred mic) ──▶ left click / ot stop
      ──▶ recordings/<name>.m4a ──▶ wolfgang ──▶ transcriptions/<name>.txt
      ──▶ notification "Copy for Gemini" ──▶ clipboard (prompt + transcript) ──▶ Gemini (browser)
```

No time windows, no network/location rules, no buffer. Nothing is recorded unless I started it; the macOS orange mic indicator shows it, and the menu bar shows a red dot with the running time.

## Decided

### Recording
- **Start/stop only by me:** left click on the menu bar icon, `ot start` / `ot stop` / `ot toggle`, or Alfred. Right click (or ⌃/⌥ click) opens the menu.
- **While recording:** `~/Library/Application Support/oton/active/<id>.caf`, 16 kHz mono 16-bit PCM. CAF stays readable when cut off by a crash. `<id>.json` next to it holds the start time and the segments (see below), rewritten whenever a segment starts.
- **On stop:** encoded to **`~/oton/recordings/<name>.m4a`** (AAC, 16 kHz mono, 32 kbit/s, ~15 MB/h), the CAF is deleted, transcription is queued. Under 1 s is discarded ("too short"). Each recording has its own id, so a new one can start while the last one is still being encoded.
- **Recordings are kept** (no retention, no auto-delete).
- **`~/oton/` (changed 2026-11-26, 0.2.1; was `~/oton/`):** colleagues may have iCloud "Desktop & Documents Folders" on, which would upload every recording; and Finder shows Documents localized ("Dokumente"). Its own folder in the home directory avoids both. 0.2.0 data is moved over on first start (file by file if both exist, never overwriting; the old folder is removed only when empty).
- **Sleep:** while recording, oton holds a `PreventUserIdleSystemSleep` assertion ("oton: recording", visible in `pmset -g assertions`). If the Mac sleeps anyway (lid closed on battery), the recording continues after wake; the missing time becomes a gap.
- **Crash / power loss:** on the next start, leftover CAFs in `active/` are encoded and transcribed, with the note "recovered after oton stopped unexpectedly". Quit while recording: the file is closed and encoded right away, Wolfgang runs on the next start.

### Microphone
- **Preferred mic is remembered:** `settings.json` → `preferredMics`, most recently chosen first (by name; a USB device's UID changes with the port). Chosen in the menu (Microphone ▸), `ot mic <n|name>`, or Alfred `ot mic`.
- **Which mic records** (`pickMic`, unit-tested):
  1. the most recently chosen mic that's connected (any kind, even Bluetooth: choosing it is explicit),
  2. otherwise any USB mic,
  3. otherwise the built-in mic.
- **Never the built-in mic with the lid closed.** The MacBook cuts it in hardware but it stays listed and records digital silence (measured 2026-11-25: −91 dB). Lid state from `ioreg` → `AppleClamshellState`. Closing the lid while recording on it switches to the next mic.
- Bluetooth and virtual devices (Teams Audio) are never picked automatically.
- **Audio engine configuration changes:** opening a device posts `AVAudioEngineConfigurationChange` itself. Re-opening on every notification looped (42 re-opens in 6 s, mic indicator flickering, no audio written). oton re-opens only when the engine has really stopped (checked 0.5 s later) and at most every 3 s; each re-open is logged.
- **Segments:** each time the mic is (re)opened (start, mic switch, disconnect, wake), a new segment starts (file offset, wall-clock start, mic name, why audio was missing before it). A disconnected mic switches to the next one with a notification; with no usable mic, the recording waits and continues when one appears.

### Transcription: Wolfgang
- `wolfgang --audio-format transcript --audio speech --timestamps --yes --json <work>/audio.m4a` (verified: Wolfgang 2.3.7 takes m4a). Wolfgang has no output-dir flag and writes `wolfgang_output/` next to its input, so each job runs in `~/Library/Application Support/oton/work/<name>/` on a hard link of the m4a.
- One job at a time. Success: transcript written, work dir deleted. "Da hab ich niemanden reden hören." → notification "No speech recognised", recording kept, no transcript. Other errors: the job stays as failed; retry from the menu or `ot retry`.
- **Post-processing:** our header replaces Wolfgang's; relative `[hh:mm:ss]` become wall-clock `[HH:mm]` via the segments; gaps get a `[gap 10:52–11:05, sleep]` line.

```
oton transcript
Date: 2026-11-26, 10:40–11:25 (45 min)
Mic: Brio 500
Gaps: 10:52–11:05 (sleep)

[10:40] …
```
- **Names:** `yy-MM-dd_HHmm-HHmm_<length>_oton` for both `.m4a` and `.txt` (e.g. `26-11-26_1040-1125_45m_oton`); a second one with the same span gets `-2`. No titles.

### Copy for Gemini
- No API (Gemini via the Workspace seat in the browser). Copy = **prompt + transcript** on the clipboard.
- The "Transcript ready" notification has a **Copy for Gemini** button (clicking the notification does the same); it copies exactly that transcript.
- `ot copy` = latest with prompt (refused while a newer recording is still being transcribed). `ot copy <n>` = plain, `--prompt` to add it, `--open` opens Gemini.
- Prompt template: `~/Library/Application Support/oton/prompt.md`, written on first start, never overwritten. Placeholders `{{transcript}}`, `{{date}}`, `{{time}}`. Default: German, no speaker attribution, Gemini decides between task mode (summary, tasks, decisions, open questions) and summary mode.

### Interfaces
1. **Menu bar** (`oton.app`, LSUIElement): only the mark at a fixed width, O = ready, O with dot = recording (hollow dot: waiting for a mic, dimmed O: transcribing). No ticking clock in the bar: it changed the item's width every second and made macOS re-place its orange mic indicator. The running time is in the tooltip. Left click start/stop; right-click menu: status, start/stop, copy latest, recent transcriptions (click = copy with prompt), microphone, retry, open folders, edit prompt, setup, quit.
2. **CLI `ot`**: talks to the app over a Unix socket (`~/Library/Application Support/oton/ot.sock`, 0600, peer UID checked), newline-delimited JSON, `--json` prints the raw lines. Starts the app itself when it isn't running.
3. **Alfred**, keyword **`ot`**: `ot` (status, start/stop, copy, list, mic), `ot start`, `ot stop`, `ot copy` (⌘↩ also opens Gemini), `ot list` (↩ with prompt, ⌘↩ plain), `ot mic`. The workflow only calls `ot alfred "<query>"` and runs `ot <arg>`.

### Build, signing, launch, distribution
- Plain SwiftPM, Command Line Tools only, arm64 (like Wolfgang: Apple chip only). Targets: `OtonCore` (testable logic), `OtonApp` (`oton` binary), `ot`.
- **No Apple developer account.** Every build is signed with the same self-signed identity **"oton Local"** (`scripts/make-cert.sh`, lives only in my keychain, so releases are built on my Mac), hardened runtime + `audio-input` entitlement. The microphone permission is tied to that certificate, so it survives updates, on colleagues' Macs too. Gatekeeper still blocks the first start: System Settings → Privacy & Security → Open Anyway (or `xattr -dr com.apple.quarantine`).
- **Distribution (decided 2026-11-26):** public GitHub repo `k1tesurfen/oton`, releases carry `oton.dmg` (oton.app, Applications link, the Alfred workflow, a background with the steps). The README's download button points at `releases/latest/download/oton.dmg`. README and release notes in German (colleagues); app, CLI and this file in English. `make release VERSION=x.y.z` tests, builds the DMG, tags, pushes and creates the release.
  - The DMG window layout is saved once in `Resources/dmg/DS_Store` (`scripts/make-dmg.sh --layout`, pauses AeroSpace so Finder keeps the size); normal builds never open Finder. The volume is always named "oton" so the layout fits every version.
- **No terminal needed for colleagues:** on first start from /Applications oton adds itself to the login items (`SMAppService.mainApp`, toggle in Setup). Setup menu: install `ot` (symlink `/usr/local/bin/ot`, admin prompt), install the Alfred workflow (bundled; it calls `/Applications/oton.app/Contents/MacOS/ot` directly, so Alfred works without the symlink). Missing Wolfgang or notification permission shows as ⚠︎ items in the menu.
- Replaced the LaunchAgent (no crash restart any more; crashed recordings are still recovered on the next start). Single-instance lock. `ot` starts the app (`open -b local.oton`) when it isn't running.
- **Self-update (0.3.0, like Wolfgang):** on start (after 20 s) and every 6 h oton asks `api.github.com/repos/k1tesurfen/oton/releases/latest`. A newer non-prerelease tag with an `oton.app.zip` asset → one notification per version ("Update" button) and "Update to oton x.y.z…" at the top of the menu; `ot update` from the terminal. Install: download the zip, unpack with `ditto`, require that the new app satisfies the running app's designated requirement (bundle id + the "oton Local" certificate) and has the expected version, `replaceItemAt` the running bundle, relaunch after this process exits. Never while recording or transcribing. No quarantine flag (URLSession), so no second Gatekeeper prompt; mic permission stays. If /Applications/oton.app isn't writable, the release page opens instead.
- `make install` (my Mac): build, replace `/Applications/oton.app`, start it; removes the old LaunchAgent and Continuum.

## Open
- Long recordings (≥ 1 h): Wolfgang throughput and Whisper hallucinations on long silences (Continuum trimmed silence before transcription; oton doesn't, yet).
- Mic placement at the office desk (Samson vs. webcam).
