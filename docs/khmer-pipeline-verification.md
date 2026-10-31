# Transcription and recap pipeline verification

## Detailed English recap acceptance

The owner selected the detailed English format from an owner-supplied example on 31 October 2026. Before changing the recap implementation, the identified failures are: losing concrete facts in a short bullet summary; inventing speaker names, decisions or dates; omitting unresolved questions or next-step owners; returning the prompt's invented example as real meeting content; losing timestamp links; and accepting empty/truncated model output. Verification must exercise the actual supplied recording and compare the resulting recap with the supplied reference, while keeping the original/reference files unchanged.

## Gemini → Claude restoration preflight

Before restoring the provider split, failure cases are: either key missing/refused; saving one key incorrectly marking setup complete; hidden Anthropic key setup; recap failure causing a second transcription; a Claude thinking block leaking into the recap; fallback leaving refused text in output; empty/refused/truncated output accepted as complete; and a stream ending without its terminal event. Exercise these through the native E2E fixture with saved artifacts. Keep the successful audio normalization and chunk-duration checks and the original detailed recap prompt.

Failure cases identified before implementation:

- An imported or recorded file has a different sample rate or multiple channels. Convert the working copy to 16 kHz mono PCM WAV; keep the original.
- A file has no readable audio, is empty, or conversion fails. Stop before uploading and show an actionable failure; remove temporary files.
- Either API key is missing or refused. Require both Gemini and Anthropic keys during setup; wait for missing keys or show the provider’s key error.
- Gemini returns no transcript, blocked content, or truncated output. Do not request or save a recap as if transcription succeeded.
- Native OGG metadata can overstate the decoded duration and make export boundaries overlap. Normalize the complete source before choosing chunk times; verify total decoded chunk duration against the normalized recording, with only codec-frame tolerance.
- A long recording needs multiple requests. Preserve Tape's chunking, timestamps and speaker continuity, and normalize each chunk.
- Recap generation fails after transcription. Keep the transcript; retry only the recap.
- The model returns thinking text, empty content or a truncated recap. Do not save it as a finished recap.
- Upload or generation fails. Attempt deletion of uploaded files and clean up local working audio.
- Users import or record audio without automatic recaps enabled. Wait for “Transcribe + summarize”; do not spend API credits during import.
- Existing English recaps and transcripts must remain readable. Do not rewrite saved files on launch.

## Repeatable E2E check

Run `python3 scripts/e2e/khmer_pipeline.py` from the repo root. It builds the debug native app and exercises its real import, conversion, Gemini and Claude HTTP clients, processor, persistence and native reader against a local Gemini and Claude fixture server. The server validates the uploaded WAV's format and the two distinct generation requests. Each run writes a JSON receipt, uploaded WAV, transcript, recap and native reader snapshots in `build/e2e/`.

For a supplied recording longer than 12 minutes, also run `python3 scripts/e2e/khmer_pipeline.py --audio /path/to/recording.ogg --audio-seconds <independently-measured-decoded-seconds> --output build/e2e-real`. This imports the actual file and checks total uploaded chunk duration (within 0.1 seconds per chunk), source integrity, persistence and the native reader. Provider replies are still invented fixtures; this mode does not test recognition quality or contact either provider.

Fixture responses prove wiring and failure recovery, not live model accuracy. Live model-quality checks are separate from these fixture assertions; see the real-recording check below. Recording permissions and capture hardware must be checked on the user's Mac.

## Local verification results (31 October 2026)

- Native E2E: all 16 scenarios passed (success, recap failure/retry, empty transcript, empty recap, truncated recap, invalid audio, empty audio, refused Gemini key, both keys missing, Gemini key missing, Anthropic key missing, refused Anthropic key, interrupted recap stream, refused recap, fallback recap, long audio).
- The fixture checked that uploaded audio was 16 kHz, mono, 16-bit PCM WAV; original source hashes stayed unchanged. Every completed upload received a delete request.
- The long-audio case exercised two native M4A chunks, speaker context and timestamp shifting before one recap call. The retry case made only one transcription call and two recap calls.
- Actual native reader captures were visually checked before processing, on the Transcript and Recap tabs, in Settings and during key setup. These contain synthetic source audio and clearly identified fixture text, not live-model evidence.
- Existing `swift test`: 37 tests passed. No new unit tests were added.
- Debug build, release build, `SIGN_IDENTITY=- scripts/build-app.sh`, `codesign --verify --strict build/Tape.app`, `python3 scripts/contrast.py` and `git diff --check` passed.
- Local app: `build/Tape.app` (ad hoc signed; not installed or released). E2E receipt: `build/e2e/receipt.json`. Reader captures: `build/e2e/success/{before-processing,transcript,recap}.png`.
- An additional native E2E with the owner-provided OGG passed. Uploaded chunks matched its independently measured decoded duration within 0.01 seconds after normalizing before splitting.
- The detailed recap E2E also checks the original detailed English prompt, adaptive high reasoning, removal of model thinking text and declined fallback text, saved numbered-topic timestamps, recording renaming and the native recap reader.
- The active pipeline uses Gemini 3.8 Flash for transcription and Claude Opus 5.5 for the detailed English recap, preserving the original recap prompt and topic playback links. Claude responses must end with `end_turn` and a terminal `message_stop`; truncated, refused, empty or interrupted output is not saved as a complete recap. See [Anthropic streaming documentation](https://platform.claude.com/docs/en/build-with-claude/streaming).
- Open: factual review of generated output, real microphone/call capture and format support on other Macs. The local build has not been installed or released.

## Real-recording check

An owner-provided Khmer/English OGG recording was tested separately with the production Swift audio preparation and Gemini clients using an existing local key. Native decoding produced 16 kHz mono PCM WAV without FFmpeg. Recap candidates were compared with the owner's supplied transcript and detailed English reference; those private inputs and generated results stay under ignored local `build/` storage and are not published in this repository.

The owner preferred the original Gemini-transcription → Claude-recap flow over the Gemini-only recap candidate. The installed original Tape app used its existing Anthropic key internally to recap the same fresh transcript. It completed normally with Claude Opus 5.5 (`end_turn`, about 37 seconds); the owner accepted that style. No key was exported or copied. This was a live comparison using the original installed app, not an end-to-end live run of the updated branch. The updated branch’s provider routing and error handling are covered by the repeatable native fixtures above.

The original detailed English recap prompt is restored. Native normalization before splitting and high-reasoning transcription remain. Live output is nondeterministic: acronym recognition, missing facts and overgeneralization still warrant human review. Private recording details, transcripts, results and credentials remain excluded from Git.

## Changed files

- Pipeline: `Sources/Tape/Processing/{AudioPreparation,Gemini,Claude,Keychain,Processor}.swift`, `Sources/TapeCore/Recap.swift`.
- Native actions and copy: `Sources/Tape/UI/{MainWindow,Onboarding,RecordingsPage,SettingsPage}.swift`, `Sources/Tape/{Library,Recorder,Toast,TapeApp}.swift`.
- Isolated E2E support: `Sources/Tape/PipelineE2E.swift`, debug-only storage hooks in `Sources/Tape/Recordings.swift`, `scripts/e2e/khmer_pipeline.py`.
- Documentation: `README.md`, this verification note.
