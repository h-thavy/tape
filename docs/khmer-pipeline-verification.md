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
- A long recording needs multiple requests. Preserve Tape's chunking, timestamps and speaker continuity, and slice the normalized PCM without re-encoding.
- Recap generation fails after transcription. Keep the transcript; retry only the recap.
- The model returns thinking text, empty content or a truncated recap. Do not save it as a finished recap.
- Upload or generation fails. Attempt deletion of uploaded files. Keep checkpoint audio only while transcription is unfinished; remove it after saving the complete transcript.
- Users import or record audio without automatic recaps enabled. Wait for “Transcribe + summarize”; do not spend API credits during import.
- Existing English recaps and transcripts must remain readable. Do not rewrite saved files on launch.

## Repeatable E2E check

Run `python3 scripts/e2e/khmer_pipeline.py` from the repo root. It builds the debug native app and exercises its real import, conversion, Gemini and Claude HTTP clients, processor, persistence and native reader against a local Gemini and Claude fixture server. The server validates the uploaded WAV's format and the two distinct generation requests. Concatenated successful PCM pieces must match the exact normalized source sample-for-sample, including after recursive splits and resume. Each run writes a JSON receipt, uploaded WAV, transcript, recap and native reader snapshots in `build/e2e/`.

For a supplied long recording, also run `python3 scripts/e2e/khmer_pipeline.py --audio /path/to/recording.ogg --audio-seconds <independently-measured-decoded-seconds> --output build/e2e-real`. This imports the actual file and checks total uploaded chunk duration (within 0.1 seconds per chunk), source integrity, persistence and the native reader. Provider replies are still invented fixtures; this mode does not test recognition quality or contact either provider.

Fixture responses prove wiring and failure recovery, not live model accuracy. Live model-quality checks are separate from these fixture assertions; see the real-recording check below. Recording permissions and capture hardware must be checked on the user's Mac.

## Local verification results (31 October 2026)

- Native E2E: all 28 scenarios passed: the original 23 cases plus recovery after repeated generic processing failure, bounded persistent processing failure, out-of-order parallel replies, parallel checkpoint restart and recursive recovery within the concurrency limit.
- The fixture checked that uploaded audio was 16 kHz, mono, 16-bit PCM WAV; original source hashes stayed unchanged. Every completed upload received a delete request.
- The 721-second fixture used three native PCM pieces with speaker context and timestamp shifting before one recap call. Recursive recovery discarded incomplete text; repeated incompleteness stopped after three requests without calling Claude. Resume skipped the completed first piece after reloading the library and creating a new processor. Recap retry made only one transcription call and two recap calls.
- Actual native reader captures were visually checked before processing, on the Transcript and Recap tabs, in Settings and during key setup. These contain synthetic source audio and clearly identified fixture text, not live-model evidence.
- Existing `swift test`: 37 tests passed. No new unit tests were added.
- Debug build, release build, `SIGN_IDENTITY=- OUT_DIR=build/parallel-release scripts/build-app.sh`, `codesign --verify --strict build/parallel-release/Tape.app`, `python3 scripts/contrast.py` and `git diff --check` passed.
- Local app: `build/parallel-release/Tape.app` (ad hoc signed; not installed or released). Final E2E receipt: `build/e2e-parallel-final/receipt.json`. Reader captures: `build/e2e-parallel-final/success/{before-processing,transcript,recap}.png`.
- An additional native E2E with the owner-provided OGG passed (`build/e2e-recovery-final-real/receipt.json`). Six pieces (300, 300, 300, 300, 300 and 98.236 seconds) matched the exact normalized PCM. Their total differed from the independent decoded duration by less than 0.007 seconds. The reader and recap metadata used the decoded duration, rather than the longer OGG container timeline. The native player retained that duration and bounded seeking at the decoded end; its updated reader capture displays 26:38 throughout.
- The detailed recap E2E also checks the original detailed English prompt, adaptive high reasoning, removal of model thinking text and declined fallback text, saved numbered-topic timestamps, recording renaming and the native recap reader.
- The active pipeline uses Gemini 3.8 Flash for transcription and Claude Opus 5.5 for the detailed English recap, preserving the original recap prompt and topic playback links. Claude responses must end with `end_turn` and a terminal `message_stop`; truncated, refused, empty or interrupted output is not saved as a complete recap. See [Anthropic streaming documentation](https://platform.claude.com/docs/en/build-with-claude/streaming).
- Open: real microphone/call capture, format support on other Macs and word-level recognition/attribution accuracy. The local build has not been installed or released.

## Real-recording check

An owner-provided Khmer/English OGG recording was tested separately with the production Swift audio preparation and Gemini clients using an existing local key. Native decoding produced 16 kHz mono PCM WAV without FFmpeg. Recap candidates were compared with the owner's supplied transcript and detailed English reference; those private inputs and generated results stay under ignored local `build/` storage and are not published in this repository.

The owner preferred the original Gemini-transcription → Claude-recap flow over the Gemini-only recap candidate. The installed original Tape app used its existing Anthropic key internally to recap the same fresh transcript. It completed normally with Claude Opus 5.5 (`end_turn`, about 37 seconds); the owner accepted that style. No key was exported or copied. This was a live comparison using the original installed app, not an end-to-end live run of the updated branch. The updated branch’s provider routing and error handling are covered by the repeatable native fixtures above.

After chunk recovery was implemented, a fresh live run of the production processing sources passed on the same owner-provided recording: five 300-second PCM pieces plus 98.236 seconds, Gemini transcription, then Claude Opus 5.5 with `end_turn`. The processor completed in 1,696 seconds (about 28 minutes), producing a 744-word English recap and six topic timestamps. No saved transcript was seeded or reused. The original input and accepted reference files remained unchanged. All six observed live pieces matched the saved normalized PCM sample-for-sample; local checkpoint and working audio cleanup completed. This particular live run did not require adaptive splitting; the recovery and restart failures are exercised by the fixtures.

Live evidence is retained privately under `build/chunk-recovery-live/`: source/build hashes, source-parity checks, provider log, audio-coverage proof, receipt and generated files. An isolated native entry point invoked the unchanged production Processor/providers/storage with the app's saved keys, without normal capture startup or the user's real library. The initial live build preceded the player-duration correction, which was checked separately against the same outputs (`final-reader/`). The final recap refinement below also includes native reader captures from the final production sources. Both readers display 26:38 and render the Khmer/English transcript and English recap.

The recap was checked against the fresh transcript and the accepted reference for assessment figures, licences, privacy restrictions, reconciliation, reporting, BOD discussion, training structure, templates, unset dates and the unfinished ending. The first recap generalized organization names and weakened a conditional request for task examples. Generic prompt refinements restored clearly stated organizations and retained proposed requests without treating them as confirmed commitments. A live Claude-only retry on the unchanged fresh transcript produced the final 746-word recap with six topic timestamps (`refined-recap-v2/run/receipt.json`). Its native reader captures use the final production sources, except for the isolated app entry point. The transcript hash matches the initial fresh live run; no additional transcription was needed. Speaker labels remain inconsistent, and the recap uses roles. This is a factual comparison with the transcript/reference, not a word-level audio audit.

The original detailed English recap format is retained, with grounding instructions to preserve material figures, organizations, constraints and input requests, separate proposals from decisions, retain uncertainty in acronyms, avoid invented deadline precision and note an unfinished recording. Native normalization before splitting and high-reasoning transcription remain. Live output is nondeterministic: acronym recognition, missing facts and overgeneralization still warrant human review. Private recording details, transcripts, results and credentials remain excluded from Git.

## Changed files

- Pipeline: `Sources/Tape/Processing/{AudioPreparation,Gemini,Claude,Keychain,Processor}.swift`, `Sources/TapeCore/Recap.swift`.
- Native actions and copy: `Sources/Tape/UI/{MainWindow,Onboarding,RecordingsPage,SettingsPage}.swift`, `Sources/Tape/{Library,Recorder,Toast,TapeApp}.swift`.
- Isolated E2E support: `Sources/Tape/PipelineE2E.swift`, debug-only storage hooks in `Sources/Tape/Recordings.swift`, `scripts/e2e/khmer_pipeline.py`.
- Documentation: `README.md`, this verification note.

## Chunk recovery preflight (before implementation)

The fresh live run at `96ef503` failed on the first 10-minute piece with Gemini status `incomplete`; Claude was not called. Failure cases for the fix: a five-minute piece is incomplete or empty; repeated incompleteness reaches a bounded minimum; a later piece fails after earlier pieces succeeded; a retry or restart loses progress; a stale checkpoint is reused for different audio/prompts; recursive splitting overlaps or drops PCM frames; timestamps/context are shifted twice; a continuation repeats forever; a provider refusal/quota/key failure is retried as if truncated; a partial transcript reaches Claude; source-container duration leaks into the reader/recap; recap invents finer-grained timing or omits material constraints/unfinished ending. Exercise the real native pipeline against deterministic failures before the fresh live run; retain receipts, source hashes and captures.

The first sample-level E2E found that separate AVFoundation decodes can differ slightly through resampling/dither and end padding. Before changing cache handling, additional failure cases are: hashing freshly decoded PCM invalidates progress for unchanged input; decoding again on retry changes the audio underneath cached pieces; a missing/corrupt prepared WAV is reused; and reference checks compare two different decodes. Fingerprint the original source and retain/validate the exact prepared WAV until the full transcript is saved. Compare accepted uploads with that same prepared WAV.

The actual-file reader capture still displayed 27:22 in its player after the library was corrected to 26:38. Before changing the reader, failure cases are: the player overwrites decoded duration with container metadata, an already-open reader misses the updated duration, a transcript timestamp expands the timeline beyond the recording, and seeking passes the decoded end. Verify the native player during the E2E and retain an updated actual-file reader capture.

Before the final recap refinement, the fresh 744-word recap preserved the main facts but generalized clearly stated organization names and weakened the request for heavy-task examples in next steps. Additional failure cases: role-based attribution erases reliable organization names; information/material requests disappear from the action list; and tentative requests become invented commitments. Refine these generic rules, then retry only Claude on the unchanged fresh transcript and retain both model outputs for comparison.

## Long-recording recovery and concurrency preflight

The Toyota 4 live check at `3414984` repeatedly failed at the second five-minute piece with Gemini's generic interaction status `failed`, including after restarting with its intact checkpoint. Before changing recovery, failure cases are: transient processing errors need the existing bounded retries; repeated processing errors need smaller pieces; persistent errors must stop at the minimum rather than loop; API key/quota/network errors must retain their existing handling; and no incomplete transcript may reach Claude. Add native E2E cases for recovery after three generic failures and bounded repeated generic failure before implementing the fix.

Before adding concurrency, failure cases are: more than three requests run at once; out-of-order replies scramble transcript timestamps or audio coverage; checkpoint writes race or overwrite successful peers; a failed piece discards other completed pieces; a retry retranscribes completed out-of-order pieces; recursive recovery exceeds the concurrency limit; new batches start after a batch has failed; and independent pieces lose the established speaker-label context. Verify these with a delayed, out-of-order native fixture, checkpoint restart and recursive recovery. Preserve the original detailed recap and require all pieces before Claude.

Generic-failure recovery was reproduced before the production edit (`build/e2e-failed-before/`). After the fix, both native E2E cases passed (`build/e2e-failed-after/receipt.json`): three failed requests followed by two successful smaller pieces, and nine bounded failed requests with no Claude call. All uploaded fixture files received cleanup requests, accepted PCM matched the exact normalized source, and the existing 37 Swift tests passed. No new unit tests were added.

Concurrency verification: the pre-change E2E measured only one active request (`build/e2e-parallel-before/http.json`). After the change, all three concurrency cases measured exactly three active requests, with later audio pieces completing first. The native processor merged their transcript markers chronologically before Claude. A failed peer preserved the other two successful checkpoints across library reload; retry uploaded only missing pieces. Recursive split requests stayed within the same three slots. Full suite: `build/e2e-parallel-final/receipt.json`; project checks: `build/parallel-checks/receipt.json` (37 existing tests, release build, strict signature, contrast and diff checks).

The first piece establishes speaker context. Subsequent windows contain at most three independent pieces and share the most recent completed context; recursive children remain sequential within their slot. Checkpoint mutations and atomic writes are serialized by an actor. A window drains its in-flight work before reporting an error, retaining successful peers and upload cleanup, and no later window or recap starts after a failure. The context wording/version changed, so checkpoints from the prior prompt are invalidated; complete saved transcripts remain reusable. The three older deterministic changed-source/cache/resume fixtures explicitly use one slot; the new parallel fixtures use the production default of three.

Fresh live long-recording retests on the concurrency build are in progress. Do not treat the earlier sequential test results as verification of the new build's model output quality.

The actual OGG native fixture was rerun with the production parallel default and passed (`build/e2e-parallel-real/receipt.json`), including all six uploaded pieces, exact normalized PCM coverage, timestamp/context handling and the 26:38 player duration. Provider replies in this check are fixtures, not recognition evidence.
