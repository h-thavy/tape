# Khmer audio pipeline verification

Failure cases identified before implementation:

- An imported or recorded file has a different sample rate or multiple channels. Convert the working copy to 16 kHz mono PCM WAV; keep the original.
- A file has no readable audio, is empty, or conversion fails. Stop before uploading and show an actionable failure; remove temporary files.
- A Gemini key is missing or refused. Wait for the key or show the key error; do not require an Anthropic key.
- Gemini returns no transcript, blocked content, or truncated output. Do not request or save a recap as if transcription succeeded.
- A long recording needs multiple requests. Preserve Tape's chunking, timestamps and speaker continuity, and normalize each chunk.
- Recap generation fails after transcription. Keep the transcript; retry only the recap.
- The model returns thinking text, empty content or a truncated recap. Do not save it as a finished recap.
- Upload or generation fails. Attempt deletion of uploaded files and clean up local working audio.
- Users import or record audio without automatic recaps enabled. Wait for “Transcribe + summarize”; do not spend API credits during import.
- Existing English recaps and transcripts must remain readable. Do not rewrite saved files on launch.

## Repeatable E2E check

Run `python3 scripts/e2e/khmer_pipeline.py` from the repo root. It builds the debug native app and exercises its real import, conversion, Gemini HTTP client, processor, persistence and native reader against a local Gemini fixture server. The server validates the uploaded WAV's format and the two distinct generation requests. Each run writes a JSON receipt, uploaded WAV, transcript, recap and native reader snapshots in `build/e2e/`.

Fixture responses prove wiring and failure recovery, not live Gemini transcription accuracy. A real Khmer recording with a valid Gemini key is still required for model-quality acceptance. Recording permissions and capture hardware must be checked on the user's Mac.

## Local verification results (31 October 2026)

- Native E2E: all 10 scenarios passed (success, recap failure/retry, empty transcript, empty recap, truncated recap, invalid audio, empty audio, refused key, missing key, long audio).
- The fixture checked that uploaded audio was 16 kHz, mono, 16-bit PCM WAV; original source hashes stayed unchanged. Every completed upload received a delete request.
- The long-audio case exercised two native M4A chunks, speaker context and timestamp shifting before one recap call. The retry case made only one transcription call and two recap calls.
- Actual native reader captures were visually checked before processing, on the Transcript tab and on the Recap tab. These contain synthetic source audio and clearly identified fixture text, not live-model evidence.
- Existing `swift test`: 37 tests passed. No new unit tests were added.
- Debug build, release build, `SIGN_IDENTITY=- scripts/build-app.sh`, `codesign --verify --strict build/Tape.app`, `python3 scripts/contrast.py` and `git diff --check` passed.
- Local app: `build/Tape.app` (ad hoc signed; not installed or released). E2E receipt: `build/e2e/receipt.json`. Reader captures: `build/e2e/success/{before-processing,transcript,recap}.png`.
- Open: live Gemini transcription/recap accuracy, real microphone/call capture and the audio formats available through the target Mac's native decoder. The old Claude client and detailed recap parser remain in the source for compatibility; the active pipeline uses Gemini only.

## Changed files

- Pipeline: `Sources/Tape/Processing/{AudioPreparation,Gemini,Keychain,Processor}.swift`, `Sources/TapeCore/Recap.swift`.
- Native actions and copy: `Sources/Tape/UI/{MainWindow,Onboarding,RecordingsPage,SettingsPage}.swift`, `Sources/Tape/{Library,Recorder,Toast,TapeApp}.swift`.
- Isolated E2E support: `Sources/Tape/PipelineE2E.swift`, debug-only storage hooks in `Sources/Tape/Recordings.swift`, `scripts/e2e/khmer_pipeline.py`.
- Documentation: `README.md`, this verification note.
