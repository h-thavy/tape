#!/usr/bin/env python3
"""Run Tape's native pipeline against a local Gemini HTTP fixture; never uses real keys."""
import argparse
import hashlib
import json
import struct
import subprocess
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TRANSCRIPT = "[00:00] Speaker 1: សួស្តី យើងនឹងប្រជុំនៅថ្ងៃស្អែក។\n[00:02] Speaker 2: យើងត្រូវរៀបចំរបាយការណ៍។"
SUMMARY = "- ក្រុមការងារនឹងប្រជុំនៅថ្ងៃស្អែក។\n- ត្រូវរៀបចំរបាយការណ៍សម្រាប់កិច្ចប្រជុំ។"


def run_case(binary, folder, scenario, seconds=4):
    folder.mkdir(parents=True, exist_ok=True)
    source = folder / "meeting.wav"
    with wave.open(str(source), "wb") as audio:
        audio.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
        # Synthetic stereo input deliberately differs from the required 16 kHz mono output.
        frame = struct.pack("<hh", 400, -200) * 48000
        for _ in range(seconds):
            audio.writeframesraw(frame)
    if scenario == "invalid-audio":
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
                    with wave.open(str(uploaded)) as audio:
                        assert audio.getframerate() == 16000
                        assert audio.getnchannels() == 1
                        assert audio.getsampwidth() == 2
                        assert audio.getnframes() > 0
                    self.reply({"file": {"name": "files/fixture", "uri": "fixture://audio", "mimeType": "audio/wav"}})
                elif self.path == "/v1beta/interactions":
                    counts["transcriptions"] += 1
                    payload = json.loads(body)
                    assert payload["model"] == "gemini-3.8-flash"
                    assert any(p.get("type") == "audio" and p.get("mime_type") == "audio/wav" for p in payload["input"])
                    assert "Khmer" in payload["input"][0]["text"]
                    if scenario == "long-audio" and counts["transcriptions"] == 2:
                        assert "part 2 of 2" in payload["input"][0]["text"]
                        assert "<previous>" in payload["input"][0]["text"]
                    text = "" if scenario == "empty-transcript" else TRANSCRIPT
                    self.reply({"status": "completed", "steps": [{"type": "model_output", "content": [{"type": "text", "text": text}]}]})
                elif self.path == "/v1beta/models/gemini-3.5-flash:generateContent":
                    counts["summaries"] += 1
                    payload = json.loads(body)
                    parts = payload["contents"][0]["parts"]
                    assert all("text" in p for p in parts), "Recap must receive text only"
                    assert all(line in parts[0]["text"] for line in TRANSCRIPT.splitlines())
                    if scenario == "long-audio":
                        assert "[10:00]" in parts[0]["text"] and "[10:02]" in parts[0]["text"]
                    assert "២-៤" in parts[0]["text"]
                    if scenario == "recap-failure-retry" and counts["summaries"] == 1:
                        return self.reply({"error": {"message": "Quota reached"}}, 429)
                    text = "" if scenario == "empty-summary" else SUMMARY
                    finish = "MAX_TOKENS" if scenario == "truncated-summary" else "STOP"
                    self.reply({"candidates": [{"finishReason": finish, "content": {"parts": [
                        {"text": "Internal reasoning must not appear in the recap.", "thought": True}, {"text": text}
                    ]}}]})
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
    if scenario in ("success", "recap-failure-retry", "long-audio"):
        assert counts["transcriptions"] == (2 if scenario == "long-audio" else 1), counts
        assert counts["summaries"] == (2 if scenario == "recap-failure-retry" else 1), counts
        assert receipt["recap"].strip() == SUMMARY
        assert all(line in receipt["transcript"] for line in TRANSCRIPT.splitlines())
        assert (folder / "recap.png").stat().st_size > 10000
        assert (folder / "transcript.png").stat().st_size > 10000
    elif scenario == "empty-transcript":
        assert counts["summaries"] == 0
    elif scenario in ("invalid-audio", "empty-audio", "missing-key"):
        assert counts["uploads"] == 0 and counts["summaries"] == 0
    assert counts["deletes"] == counts["uploads"], counts
    print(f"PASS {scenario}: {folder / 'receipt.json'}")
    return {"scenario": scenario, "passed": True, "counts": counts}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "build/e2e")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    if not args.skip_build:
        subprocess.run(["swift", "build", "--product", "Tape"], cwd=ROOT, check=True)
    binpath = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip()
    cases = ["success", "recap-failure-retry", "empty-transcript", "empty-summary", "truncated-summary",
             "invalid-audio", "empty-audio", "refused-key", "missing-key", "long-audio"]
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    receipts = [run_case(Path(binpath) / "Tape", args.output / case, case,
                        721 if case == "long-audio" else 0 if case == "empty-audio" else 4) for case in cases]
    (args.output / "receipt.json").write_text(json.dumps({"passed": True, "mode": "local Gemini fixtures, synthetic audio", "cases": receipts}, indent=2))


if __name__ == "__main__":
    main()
