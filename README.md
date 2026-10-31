# Tape

Records your calls on a Mac and turns each one into a meeting recap: Gemini writes the transcript
(Khmer and English terms as spoken), then Claude writes a detailed English meeting recap. No account, no sign-in: add your own Gemini and Anthropic API keys.

## Install

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/h-thavy/tape/main/scripts/install.sh | bash
```

Then open **Settings** in Tape and add a [Gemini API key](https://aistudio.google.com/apikey) for transcription and an [Anthropic API key](https://platform.claude.com/) for recaps. Needs macOS 14.2 or later on Apple Silicon.

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
  the same time for 3 seconds. The camera notch grows into a "Meeting detected" island (also over full-screen
  calls; on a Mac without a notch it drops from the top edge), with the platform's icon: the call app's own,
  or for a call in a browser, the platform's (its desktop app's when installed, else its web icon, fetched
  once). Or turn on *Record calls without asking*.
- **Lives in the notch.** Hover over the notch for quick actions: record, import, open Tape, the latest
  recording. While recording, the notch shows the time and your mic's level (a crossed-out mic while you're
  muted). Drag recordings to the notch to import them. The island stays off screen shares and screen
  recordings: people you share your whole screen with don't see it.
- **Stops when the call ends.** The recording is encoded while you talk, so it's saved the moment the call
  ends, trimmed to where the call left the microphone.
- **Transcribes and summarizes when you ask.** Import audio or record a call, then press
  *Transcribe + summarize* on a recording (or on the "Recording saved" card, or for several at once).
  Tape prepares a temporary **16 kHz mono PCM WAV** using native macOS audio decoding, preserving the
  original. Gemini (`gemini-3.8-flash`) writes the timestamped Khmer transcript, keeping English terms as
  spoken. A text-only Claude call (`claude-opus-5-5`) writes a detailed **English meeting recap**:
  context, topic sections, decisions, open questions and next steps by owner. Topic timestamps link back
  to the recording. Both calls use high reasoning; processing a long meeting can take several minutes.
  Both appear in the recording's **Transcript** and **Recap** tabs and are saved next to the audio.
  Tape normalizes before splitting, avoiding inaccurate source-format timelines. Recordings over 12 minutes
  are transcribed in 10-minute parts, with timestamps and speaker labels carried
  forward. If the recap fails, retrying reuses the saved transcript. Processing starts only when you ask,
  unless you turn on *Make recaps automatically* in Settings. No Flask, Python server or FFmpeg is required:

  ```
  ~/Documents/Tape/2026-10-30 14.05 Google Meet in Opera GX.m4a
  ~/Documents/Tape/2026-10-30 14.05 Google Meet in Opera GX.transcript.txt
  ~/Documents/Tape/2026-10-30 14.05 Google Meet in Opera GX.recap.md
  ```

- **Recaps recordings you already have.** Use **Import** (or drop files on the window) for recordings from
  before Tape or from anywhere else: audio (m4a, mp3, wav, aac, flac, ogg…) or video (the sound is taken out).
  Recordings already in `~/Documents/Tape` show up by themselves, with a "Transcribe + summarize" button.
- **Follows the call's mute button.** Muted in the meeting: your mic is left out entirely. Unmuted: it's
  recorded. The introduction doesn't go on until all three permissions are allowed; after that, Tape asks for
  them at every launch while one is missing, and again whenever one is
  turned off; while it can't see the mute button, the notch and the window say so. (Needs Accessibility. A browser shows only its visible tab, so while a browser call's tab is in
  the background Tape keeps the last state it saw.)
- **Keeps the meeting name.** A recording takes the meeting's title when its window shows one ("Meet – Weekly sync",
  "Pricing review | Microsoft Teams"), otherwise the topic from the recap. Imports start with their file names. Click the title to rename it. Its files
  take the name (`<name>.m4a`, `.transcript.txt`, `.recap.md`), and it appears in Tape.
- **Library.** ⌘-click or ⇧-click to pick several recordings, then move them to the Trash (Finder's Put Back
  restores them). *Copy recording* puts the audio file on the clipboard, to paste into a chat, an email or
  Finder; recordings can also be dragged out of the library.
- **Updates itself.** Tape checks GitHub for a new version and updates in one click (never during a recording
  or a recap), keeping your recordings, keys and settings. No need to run the install command again. A new
  version puts a dot on the menu bar icon; click the icon and *Update to Tape x.y.z* is at the top.
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

## Design

Black and white, with colour only where it means something: one per speaker, green/amber/red for a recap's
status, red for a recording. Every text colour passes WCAG AA (4.5:1) and every speaker colour 3:1
(`python3 scripts/contrast.py` checks the values in `Theme.swift`). Controls have VoiceOver labels, the
meeting map is adjustable with VoiceOver (15 s steps), and animations stop under Reduce Motion. Type is
[Geist](https://github.com/vercel/geist-font) (OFL), bundled.

## Privacy

Recordings, transcripts and recaps are saved in `~/Documents/Tape`. To process one, a temporary 16 kHz mono
WAV is sent to Google (Gemini) for transcription, then its transcript is sent to Anthropic (Claude) for the recap, using
your respective keys. Tape attempts to delete the uploaded audio after transcription, including on failure, and removes
the local working WAV. Your API keys are kept in the macOS Keychain. Existing saved recaps remain readable.

## Build from source

```sh
scripts/build-app.sh        # → build/Tape.app, signed with your Apple Development identity
open build/Tape.app
swift test                  # existing mixer, mic alignment, prompts, transcripts and recaps checks
python3 scripts/e2e/khmer_pipeline.py  # native pipeline E2E, local Gemini and Claude fixtures and saved artifacts
scripts/release.sh          # dist/Tape.zip for a GitHub release (--publish to upload it)
swift scripts/make-icon.swift   # the cassette icon (same geometry as TapeMark, which also draws the menu bar icon)
```

Test hooks: `open --env TAPE_TEST_RECORD=10 build/Tape.app` records for 10 s, saves and quits;
`--env TAPE_TEST_IMPORT=<file>,<file>` imports files and quits;
`--env TAPE_TEST_TRANSCRIBE=<file> --env TAPE_TEST_OUT=<file>` transcribes a file with Gemini and quits;
`--env TAPE_ONBOARDING=1` shows the introduction; `--env TAPE_DEBUG_TRACKS=1` also keeps the raw `mic.caf` and `call.caf` (in
`~/Library/Application Support/Tape/Recording`); `--env TAPE_DEBUG_AX=1` logs what the mute-button search
sees; `--env TAPE_SNAPSHOT=<folder>` saves the window's pages (light and dark), the introduction and the notch
island's states as PNGs, and quits; `--env TAPE_TEST_VERSION=0.1.0
--env TAPE_TEST_AUTOUPDATE=1` runs the self-update from GitHub.

## Layout

- `Sources/TapeCore`: pure logic, unit tested. `TapeMix.swift` (mixer, echo handling, mute timeline),
  `MicLine.swift` (lining the mic up with the call, cross-fades), `Recap.swift` (the transcription and recap prompts, detailed recap format, the recap's Markdown and topics), `Transcript.swift` (lines, speakers and turns, parts' times), `CallRules.swift` (which apps are calls, mute button wording).
- `Sources/Tape`: the app. `CallCapture` (tap + aggregate device, microphones), `TapeWriter` (mix and
  encode), `Recordings` (folder, repackaging, crash recovery), `Library` (recordings and their files),
  `Processing/` (Gemini, Claude, native WAV preparation, the Keychain and the pipeline), `CallWatcher`, `MuteWatcher`, `Recorder`,
  `Toast` (the notch island's cards), `NotchBar` (the notch's quick actions and live strip), `UI/` (window,
  library and reader, Settings, the introduction, theme),
  `TapeApp` (app and menu bar).
- `scripts/`: build, release, install and icon scripts.

## Verify the transcription and recap pipeline

`python3 scripts/e2e/khmer_pipeline.py` runs the native debug app against a local Gemini and Claude fixture service,
using synthetic stereo audio and dummy credentials. It covers success, missing/refused keys, invalid audio,
empty/truncated responses, long recordings and retrying a failed recap without re-transcription. It writes
repeatable receipts, uploaded WAVs, transcripts, recaps and native reader snapshots to `build/e2e/`.
This verifies integration, not live model accuracy. See [verification details](docs/khmer-pipeline-verification.md).
