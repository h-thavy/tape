# Tape

Records your calls on a Mac and turns each one into a meeting recap: Gemini writes the transcript
(Khmer and English as spoken), Claude writes the recap. No account, no sign-in: you add your own API keys.

## Install

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/h-thavy/tape/main/scripts/install.sh | bash
```

Then open **Settings** in Tape and add a [Gemini API key](https://aistudio.google.com/apikey) and an
[Anthropic API key](https://console.anthropic.com/settings/keys). Needs macOS 14.2 or later on Apple Silicon.

<details>
<summary><b>Uninstall</b></summary>

```sh
curl -fsSL https://raw.githubusercontent.com/h-thavy/tape/main/scripts/install.sh | bash -s -- --uninstall
# also delete settings, the saved API keys and the recordings index (recordings themselves are kept):
curl -fsSL https://raw.githubusercontent.com/h-thavy/tape/main/scripts/install.sh | bash -s -- --uninstall --purge
```
</details>

## What it does

- **Asks when a call starts.** Zoom, Teams, FaceTime, Webex, Google Meet or any call in a browser, Slack
  huddles, Discord, WhatsApp, Telegram, Signal… and any other app that uses the microphone and plays audio at
  the same time for 3 seconds. A "Meeting detected" card appears above the Dock (also over full-screen calls),
  as in Onword. Or turn on *Record calls without asking*.
- **Stops when the call ends.** The recording is encoded while you talk, so it's saved the moment the call
  ends, trimmed to where the call left the microphone.
- **Writes the recap.** The recording goes to Gemini (`gemini-3.8-flash`, the best at Khmer mixed with
  English) for a timestamped transcript, then to Claude (Claude Opus 5.5) for the recap: what the meeting was,
  one section per topic with the decisions, details and open questions, and the next steps. Both are saved
  next to the recording and shown in the app:

  ```
  ~/Documents/Tape/2026-10-30 14.05 Google Meet in Opera GX.m4a
  ~/Documents/Tape/2026-10-30 14.05 Google Meet in Opera GX.transcript.txt
  ~/Documents/Tape/2026-10-30 14.05 Google Meet in Opera GX.recap.md
  ```

- **Follows the call's mute button.** Muted in the meeting: your mic is left out entirely. Unmuted: it's
  recorded. (Needs Accessibility. A browser shows only its visible tab, so while a browser call's tab is in
  the background Tape keeps the last state it saw.)
- **Switching devices mid-call is seamless.** Speakers → AirPods, a new mic, a headset going into call mode:
  the other people keep recording without a break, and your mic hands over with a 10 ms cross-fade.

## Why it sounds like the call

| | What Tape does |
| --- | --- |
| The other people | Captured with a Core Audio process tap, **in stereo**, before the volume control: exactly what the call app played. Encoded **once** (48 kHz AAC, 128 kbps); never decoded and re-encoded. |
| Timing | The call is read through a private device clocked by the Mac's built-in output, which never changes, so plugging in headphones never restarts it. Your mic is read on its own and placed on the call's timeline by timestamp, with clock drift absorbed by stretching it by at most 0.2 % (never by jumping). |
| Bluetooth headsets | Using a headset's mic switches it into call mode (mono, 16–24 kHz) for everything you hear. Tape uses it only once the call does; until then your voice comes from the Mac's mic and the headset stays in full quality. For the best recording, pick the Mac's microphone in the call app. |
| Your mic on speakers | The other side's voice also reaches your mic from the room, ~60 ms later. Tape recognises that echo (its loudness follows the call's) and turns your mic down while it's only echo, so voices aren't heard twice. Talking over them keeps your mic open. |
| Your mic in general | Gently levelled, and lowered between your words so room hiss doesn't sit under everyone. |
| Your voice coming back | With another device near you in the same call, your voice comes back through the call 0.1–1.5 s later. Tape turns the call down for those moments (unless you're muted, when the call's copy is the only one). |

## Privacy

Recordings, transcripts and recaps stay in `~/Documents/Tape`. A recording is sent to Google (Gemini) and its
transcript to Anthropic (Claude) only to make the recap, with your keys; the uploaded audio is deleted from
Google right after. The keys are kept in the macOS Keychain.

## Build from source

```sh
scripts/build-app.sh        # → build/Tape.app, signed with your Apple Development identity
open build/Tape.app
swift test                  # the mixer, mic alignment, recap prompts and Markdown
scripts/release.sh          # dist/Tape.zip for a GitHub release (--publish to upload it)
swift scripts/make-icon.swift
```

Test hooks: `open --env TAPE_TEST_RECORD=10 build/Tape.app` records for 10 s, saves and quits;
`--env TAPE_DEBUG_TRACKS=1` also keeps the raw `mic.caf` and `call.caf` (in
`~/Library/Application Support/Tape/Recording`); `--env TAPE_DEBUG_AX=1` logs what the mute-button search
sees; `--env TAPE_SNAPSHOT=<folder>` saves the window's pages as PNGs.

## Layout

- `Sources/TapeCore`: pure logic, unit tested. `TapeMix.swift` (mixer, echo handling, mute timeline),
  `MicLine.swift` (lining the mic up with the call, cross-fades), `Recap.swift` (the Gemini and Claude
  prompts, the recap's Markdown), `CallRules.swift` (which apps are calls, mute button wording).
- `Sources/Tape`: the app. `CallCapture` (tap + aggregate device, microphones), `TapeWriter` (mix and
  encode), `Recordings` (folder, repackaging, crash recovery), `Library` (recordings and their files),
  `Processing/` (Gemini, Claude, the Keychain, the pipeline), `CallWatcher`, `MuteWatcher`, `Recorder`,
  `Toast` (the card above the Dock), `UI/` (window, Recordings, Settings, theme shared with Onword),
  `TapeApp` (app and menu bar).
- `scripts/`: build, release, install and icon scripts.
