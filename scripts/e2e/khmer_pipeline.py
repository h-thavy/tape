#!/usr/bin/env python3
"""Run Tape's native pipeline against local Gemini and Claude HTTP fixtures; never uses real keys."""
import argparse
import hashlib
import json
import math
import struct
import subprocess
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TRANSCRIPT = "[00:00] Speaker 1: សួស្តី យើងនឹងប្រជុំនៅថ្ងៃស្អែក។\n[00:02] Speaker 2: យើងត្រូវរៀបចំរបាយការណ៍។"
SUMMARY = '# "Team planning" — Meeting Recap\n\nSource: recording "meeting". Speakers are labelled by role.\n\nA short planning meeting. Topics: tomorrow’s meeting and the report.\n\n## 1. Meeting and report\n\n- **Plan:** meet tomorrow and prepare the report.\n\n## Next steps\n\n- Team: prepare the report.'


def run_case(binary, folder, scenario, seconds=4, audio_path=None):
    folder.mkdir(parents=True, exist_ok=True)
    source = audio_path.resolve() if audio_path else folder / "meeting.wav"
    if not audio_path:
        with wave.open(str(source), "wb") as audio:
            audio.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
            # Synthetic stereo input deliberately differs from the required 16 kHz mono output.
            frame = struct.pack("<hh", 400, -200) * 48000
            for _ in range(seconds):
                audio.writeframesraw(frame)
    expected_parts = math.ceil(seconds / 300)
    summary = SUMMARY.replace('recording "meeting"', f'recording "{source.stem}"')
    uploaded_seconds = []
    accepted_pcm = []
    last_pcm = b""
    if scenario == "invalid-audio" and not audio_path:
        source.write_bytes(b"not an audio recording")
    with source.open("rb") as stream:
        source_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    events = []
    counts = {"transcriptions": 0, "summaries": 0, "uploads": 0, "deletes": 0}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, value, status=200, headers=None):
            data = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            for key, val in (headers or {}).items():
                self.send_header(key, val)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            nonlocal last_pcm
            try:
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                events.append({"method": "POST", "path": self.path})
                if self.path == "/upload/v1beta/files":
                    assert self.headers["X-Goog-Upload-Header-Content-Type"] == "audio/wav"
                    assert self.headers["x-goog-api-key"] == "fixture-key"
                    if scenario == "refused-key":
                        return self.reply({"error": {"message": "API key invalid"}}, 403)
                    self.reply({}, headers={"X-Goog-Upload-URL": f"http://127.0.0.1:{self.server.server_port}/upload-bytes"})
                elif self.path == "/upload-bytes":
                    counts["uploads"] += 1
                    uploaded = folder / f"uploaded-{counts['uploads']}.wav"
                    uploaded.write_bytes(body)
                    last_pcm = body[44:]
                    with wave.open(str(uploaded)) as audio:
                        assert audio.getframerate() == 16000
                        assert audio.getnchannels() == 1
                        assert audio.getsampwidth() == 2
                        assert audio.getnframes() > 0
                        uploaded_seconds.append(audio.getnframes() / audio.getframerate())
                    self.reply({"file": {"name": "files/fixture", "uri": "fixture://audio", "mimeType": "audio/wav"}})
                elif self.path == "/v1beta/interactions":
                    counts["transcriptions"] += 1
                    payload = json.loads(body)
                    assert payload["model"] == "gemini-3.8-flash"
                    assert payload["generation_config"]["thinking_level"] == "high"
                    assert any(p.get("type") == "audio" and p.get("mime_type") == "audio/wav" for p in payload["input"])
                    assert "Khmer" in payload["input"][0]["text"]
                    if scenario == "long-audio" and counts["transcriptions"] == 2:
                        assert f"part 2 of {expected_parts}" in payload["input"][0]["text"]
                        assert "<previous>" in payload["input"][0]["text"]
                    if scenario in ("resume-transcription", "changed-audio-retry", "corrupt-cache-retry") and counts["transcriptions"] == 2:
                        if scenario in ("changed-audio-retry", "corrupt-cache-retry"):
                            accepted_pcm.clear()
                        return self.reply({"error": {"message": "Quota reached"}}, 429)
                    if scenario == "bounded-failed" or (scenario == "failed-recovery" and counts["transcriptions"] <= 3):
                        return self.reply({"status": "failed", "errors": [{"message": "There was a problem processing your request."}]})
                    if scenario == "bounded-incomplete" or (scenario in ("incomplete-recovery", "continuation-recovery") and counts["transcriptions"] == 1):
                        return self.reply({"status": "requires_continuation" if scenario == "continuation-recovery" else "incomplete",
                                           "usage": {"total_output_tokens": 65536},
                                           "steps": [{"type": "model_output", "content": [{"type": "text", "text": "[00:00] Speaker 1: Discard incomplete text"}]}]})
                    text = "" if scenario == "empty-transcript" or (scenario == "empty-piece-recovery" and counts["transcriptions"] == 1) else TRANSCRIPT
                    if text:
                        accepted_pcm.append(last_pcm)
                    self.reply({"status": "completed", "steps": [{"type": "model_output", "content": [{"type": "text", "text": text}]}]})
                elif self.path == "/v1/messages":
                    counts["summaries"] += 1
                    payload = json.loads(body)
                    assert self.headers["x-api-key"] == "fixture-claude-key"
                    assert self.headers["anthropic-version"] == "2026-10-21"
                    assert self.headers["anthropic-beta"] == "server-side-fallback-2026-07-01"
                    assert payload["model"] == "claude-opus-5-5"
                    assert payload["stream"] is True and payload["thinking"]["type"] == "adaptive"
                    assert payload["output_config"]["effort"] == "high"
                    assert payload["fallbacks"] == "default"
                    text_input = payload["messages"][0]["content"]
                    assert isinstance(text_input, str), "Claude must receive text only"
                    assert all(line in text_input for line in TRANSCRIPT.splitlines())
                    if scenario == "long-audio":
                        assert "[05:00]" in text_input and "[10:00]" in text_input
                    system = payload["system"]
                    assert "Write the recap in English" in system
                    assert "Next steps" in system and "never guess a name" in system
                    if scenario == "refused-claude-key":
                        return self.reply({"error": {"message": "Invalid API key"}}, 401)
                    if scenario == "recap-failure-retry" and counts["summaries"] == 1:
                        return self.reply({"error": {"message": "Quota reached"}}, 429)
                    text = "" if scenario == "empty-summary" else summary + "\n\n[topic times] 1=00:00"
                    stream = [{"type": "message_start", "message": {"model": "claude-opus-5-5"}},
                              {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking"}},
                              {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Private reasoning"}},
                              {"type": "content_block_stop", "index": 0}]
                    if scenario == "fallback-summary":
                        stream += [
                            {"type": "content_block_start", "index": 1, "content_block": {"type": "text"}},
                            {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Declined partial reply"}},
                            {"type": "content_block_stop", "index": 1},
                            {"type": "content_block_start", "index": 2, "content_block": {"type": "fallback", "model": "fixture-fallback"}},
                            {"type": "content_block_stop", "index": 2},
                        ]
                    stream += [{"type": "content_block_start", "index": 3, "content_block": {"type": "text"}},
                               {"type": "content_block_delta", "index": 3, "delta": {"type": "text_delta", "text": text}},
                               {"type": "content_block_stop", "index": 3},
                               {"type": "message_delta", "delta": {"stop_reason": "max_tokens" if scenario == "truncated-summary" else "refusal" if scenario == "refused-summary" else "end_turn"}}]
                    if scenario != "interrupted-summary":
                        stream.append({"type": "message_stop"})
                    data = "".join("event: " + event["type"] + "\ndata: " + json.dumps(event, ensure_ascii=False) + "\n\n" for event in stream).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                else:
                    raise AssertionError(f"Unexpected endpoint {self.path}")
            except Exception as error:
                events.append({"fixture_error": str(error)})
                self.reply({"error": {"message": "Fixture assertion failed"}}, 400)

        def do_GET(self):
            events.append({"method": "GET", "path": self.path})
            self.reply({"state": "ACTIVE"})

        def do_DELETE(self):
            counts["deletes"] += 1
            events.append({"method": "DELETE", "path": self.path})
            self.reply({})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run([str(binary), "--pipeline-e2e", str(folder),
                                 f"http://127.0.0.1:{server.server_port}", scenario, str(source)],
                                capture_output=True, text=True, timeout=180)
        (folder / "native.log").write_text(result.stdout + result.stderr)
    finally:
        server.shutdown()
    (folder / "http.json").write_text(json.dumps({"counts": counts, "events": events}, indent=2))
    assert result.returncode == 0, f"{scenario}: native app failed; see {folder}/native.log"
    receipt = json.loads((folder / "receipt.json").read_text())
    assert receipt["passed"], receipt
    with source.open("rb") as stream:
        assert hashlib.file_digest(stream, "sha256").hexdigest() == source_hash, "Source audio changed"
    assert not any("fixture_error" in event for event in events), events
    if scenario in ("success", "recap-failure-retry", "long-audio", "fallback-summary", "incomplete-recovery", "continuation-recovery", "empty-piece-recovery", "resume-transcription", "changed-audio-retry", "corrupt-cache-retry", "failed-recovery"):
        expected_requests = {"long-audio": expected_parts, "incomplete-recovery": 3, "continuation-recovery": 3,
                             "empty-piece-recovery": 3, "resume-transcription": 4, "changed-audio-retry": 5, "corrupt-cache-retry": 5, "failed-recovery": 5}.get(scenario, 1)
        assert counts["transcriptions"] == expected_requests, counts
        assert "Discard incomplete text" not in receipt["transcript"]
        with wave.open(str(folder / "reference.wav")) as reference:
            assert b"".join(accepted_pcm) == reference.readframes(reference.getnframes()), "Pieces lost, repeated or altered PCM frames"
        # Allow codec/resampler padding; the exact coverage check above uses the same prepared WAV.
        assert abs(receipt["duration"] - seconds) < 0.05
        assert receipt["player_duration"] == receipt["duration"]
        assert counts["summaries"] == (2 if scenario == "recap-failure-retry" else 1), counts
        # Tape renames the recording and its source reference from the recap title.
        expected = summary.replace(f'Source: recording "{source.stem}"', 'Source: recording "Team planning"')
        assert receipt["recap"].strip() == expected
        assert all(line in receipt["transcript"] for line in TRANSCRIPT.splitlines())
        assert (folder / "recap.png").stat().st_size > 10000
        assert (folder / "transcript.png").stat().st_size > 10000
    elif scenario == "bounded-incomplete":
        assert counts["transcriptions"] == 3 and counts["summaries"] == 0, counts
    elif scenario == "bounded-failed":
        assert counts["transcriptions"] == 9 and counts["summaries"] == 0, counts
    elif scenario == "empty-transcript":
        assert counts["summaries"] == 0
    elif scenario in ("invalid-audio", "empty-audio", "missing-key", "missing-gemini-key", "missing-claude-key"):
        assert counts["uploads"] == 0 and counts["summaries"] == 0
    assert counts["deletes"] == counts["uploads"], counts
    if scenario == "long-audio":
        assert abs(sum(uploaded_seconds) - seconds) < expected_parts * 0.1, uploaded_seconds
        (folder / "audio-duration.json").write_text(json.dumps({
            "source_seconds": seconds, "uploaded_seconds": uploaded_seconds,
            "difference_seconds": sum(uploaded_seconds) - seconds,
        }, indent=2))
    print(f"PASS {scenario}: {folder / 'receipt.json'}")
    return {"scenario": scenario, "passed": True, "counts": counts}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "build/e2e")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--audio", type=Path, help="Optional local recording; still uses fixture provider replies")
    parser.add_argument("--audio-seconds", type=float, help="Independently measured decoded duration for --audio")
    args = parser.parse_args()
    if args.audio and (not args.audio.is_file() or not args.audio_seconds or args.audio_seconds <= 720):
        parser.error("--audio requires an existing recording and --audio-seconds greater than 720")
    if not args.skip_build:
        subprocess.run(["swift", "build", "--product", "Tape"], cwd=ROOT, check=True)
    binpath = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip()
    cases = ["success", "recap-failure-retry", "empty-transcript", "empty-summary", "truncated-summary",
             "invalid-audio", "empty-audio", "refused-key", "missing-key", "missing-gemini-key", "missing-claude-key",
             "refused-claude-key", "interrupted-summary", "refused-summary", "fallback-summary", "long-audio", "incomplete-recovery", "continuation-recovery", "empty-piece-recovery",
             "bounded-incomplete", "resume-transcription", "changed-audio-retry", "corrupt-cache-retry", "failed-recovery", "bounded-failed"]
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if args.audio:
        receipts = [run_case(Path(binpath) / "Tape", args.output / "real-audio", "long-audio",
                             args.audio_seconds, args.audio)]
    else:
        receipts = [run_case(Path(binpath) / "Tape", args.output / case, case,
                        721 if case == "long-audio" else 604 if case in ("resume-transcription", "changed-audio-retry", "corrupt-cache-retry") else 240 if case in ("incomplete-recovery", "continuation-recovery", "empty-piece-recovery", "bounded-incomplete", "failed-recovery", "bounded-failed") else 0 if case == "empty-audio" else 4) for case in cases]
    (args.output / "receipt.json").write_text(json.dumps({"passed": True, "mode": "local Gemini and Claude fixtures, supplied audio" if args.audio else "local Gemini and Claude fixtures, synthetic audio", "cases": receipts}, indent=2))


if __name__ == "__main__":
    main()
