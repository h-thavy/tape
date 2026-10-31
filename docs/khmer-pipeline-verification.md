# Transcription and recap pipeline verification

## Detailed English recap acceptance

The owner selected the detailed English format from an owner-supplied example on 31 October 2026. Before changing the recap implementation, the identified failures are: losing concrete facts in a short bullet summary; inventing speaker names, decisions or dates; omitting unresolved questions or next-step owners; returning the prompt's invented example as real meeting content; losing timestamp links; and accepting empty/truncated model output. Verification must exercise the actual supplied recording and compare the resulting recap with the supplied reference, while keeping the original/reference files unchanged.

Failure cases identified before implementation:

- An imported or recorded file has a different sample rate or multiple channels. Convert the working copy to 16 kHz mono PCM WAV; keep the original.
- A file has no readable audio, is empty, or conversion fails. Stop before uploading and show an actionable failure; remove temporary files.
- A Gemini key is missing or refused. Wait for the key or show the key error; do not require an Anthropic key.
- Gemini returns no transcript, blocked content, or truncated output. Do not request or save a recap as if transcription succeeded.
- Native OGG metadata can overstate the decoded duration and make export boundaries overlap. Normalize the complete source before choosing chunk times; verify total decoded chunk duration against the normalized recording, with only codec-frame tolerance.
- A long recording needs multiple requests. Preserve Tape's chunking, timestamps and speaker continuity, and normalize each chunk.
- Recap generation fails after transcription. Keep the transcript; retry only the recap.
- The model returns thinking text, empty content or a truncated recap. Do not save it as a finished recap.
- Upload or generation fails. Attempt deletion of uploaded files and clean up local working audio.
- Users import or record audio without automatic recaps enabled. Wait for “Transcribe + summarize”; do not spend API credits during import.
- Existing English recaps and transcripts must remain readable. Do not rewrite saved files on launch.

## Repeatable E2E check

Run `python3 scripts/e2e/khmer_pipeline.py` from the repo root. It builds the debug native app and exercises its real import, conversion, Gemini HTTP client, processor, persistence and native reader against a local Gemini fixture server. The server validates the uploaded WAV's format and the two distinct generation requests. Each run writes a JSON receipt, uploaded WAV, transcript, recap and native reader snapshots in `build/e2e/`.

For a supplied recording longer than 12 minutes, also run `python3 scripts/e2e/khmer_pipeline.py --audio /path/to/recording.ogg --audio-seconds <independently-measured-decoded-seconds> --output build/e2e-real`. This imports the actual file and checks total uploaded chunk duration (within 0.1 seconds per chunk), source integrity, persistence and the native reader. Gemini replies are still invented fixtures; this mode does not test recognition quality or contact Google.

Fixture responses prove wiring and failure recovery, not live Gemini transcription accuracy. Live model-quality checks are separate from these fixture assertions; see the real-recording check below. Recording permissions and capture hardware must be checked on the user's Mac.

## Local verification results (31 October 2026)

- Native E2E: all 10 scenarios passed (success, recap failure/retry, empty transcript, empty recap, truncated recap, invalid audio, empty audio, refused key, missing key, long audio).
- The fixture checked that uploaded audio was 16 kHz, mono, 16-bit PCM WAV; original source hashes stayed unchanged. Every completed upload received a delete request.
- The long-audio case exercised two native M4A chunks, speaker context and timestamp shifting before one recap call. The retry case made only one transcription call and two recap calls.
- Actual native reader captures were visually checked before processing, on the Transcript tab and on the Recap tab. These contain synthetic source audio and clearly identified fixture text, not live-model evidence.
- Existing `swift test`: 37 tests passed. No new unit tests were added.
- Debug build, release build, `SIGN_IDENTITY=- scripts/build-app.sh`, `codesign --verify --strict build/Tape.app`, `python3 scripts/contrast.py` and `git diff --check` passed.
- Local app: `build/Tape.app` (ad hoc signed; not installed or released). E2E receipt: `build/e2e/receipt.json`. Reader captures: `build/e2e/success/{before-processing,transcript,recap}.png`.
- An additional native E2E with the owner-provided OGG passed. Uploaded chunks matched its independently measured decoded duration within 0.01 seconds after normalizing before splitting.
- The detailed recap E2E also checks role-based English instructions, high reasoning, removal of model thinking text, saved numbered-topic timestamps, recording renaming and the native recap reader.
- Open: human acceptance of live transcription/recap accuracy, real microphone/call capture and format support on other Macs. The old Claude client remains unused; the active pipeline uses Gemini 3.8 Flash for both steps and the detailed recap parser supplies topic links.

## Real-recording check

An owner-provided Khmer/English OGG recording was tested separately with the production Swift audio preparation and Gemini clients using an existing local key. Native decoding produced 16 kHz mono PCM WAV without FFmpeg. Recap candidates were compared with the owner's supplied transcript and detailed English reference; those private inputs and generated results stay under ignored local `build/` storage and are not published in this repository.

The comparison exposed speech-recognition errors in product names and acronyms and factual omissions in short or faster recaps. The updated pipeline uses high reasoning for transcription and the detailed English recap, preserves role-based attribution and the existing topic-time parser, and asks for explicit uncertainty rather than invented names or commitments. This is a quality improvement, not proof that every generated statement is correct. Live model output remains nondeterministic, and a longer reasoning run can take substantially longer than the original configuration.

## Changed files

- Pipeline: `Sources/Tape/Processing/{AudioPreparation,Gemini,Keychain,Processor}.swift`, `Sources/TapeCore/Recap.swift`.
- Native actions and copy: `Sources/Tape/UI/{MainWindow,Onboarding,RecordingsPage,SettingsPage}.swift`, `Sources/Tape/{Library,Recorder,Toast,TapeApp}.swift`.
- Isolated E2E support: `Sources/Tape/PipelineE2E.swift`, debug-only storage hooks in `Sources/Tape/Recordings.swift`, `scripts/e2e/khmer_pipeline.py`.
- Documentation: `README.md`, this verification note.
