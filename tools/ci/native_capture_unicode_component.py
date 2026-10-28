"""Run two partial native rounds against an isolated Unicode HTTP fixture."""

import argparse
import base64
import hashlib
import http.server
import json
import os
import shutil
import subprocess
import threading
import time
import uuid
from pathlib import Path


def scalar_tree(value):
    if isinstance(value, str):
        value.encode("utf-8", "strict")
    elif isinstance(value, list):
        for item in value:
            scalar_tree(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            scalar_tree(key)
            scalar_tree(item)


def verify(output, calls, elapsed_seconds):
    raw = (output / "trajectory.jsonl").read_bytes()
    rows = [json.loads(line) for line in raw.decode("utf-8", "strict").splitlines()]
    scalar_tree(rows)
    decisions = [row for row in rows if "action_status" in row]
    assert len(decisions) == 16
    forensic = [
        row
        for row in decisions
        if "invalid_native_evidence_json_b64" in row["observation"]
    ]
    assert len(forensic) >= 4
    for row in forensic:
        assert (
            row["executed_action"] is None
            and row["selected_attempt_id"] is None
            and row["attempts"] == []
        )
        assert row["action_status"] == "rejected"
        original = base64.b64decode(
            row["observation"]["invalid_native_evidence_json_b64"], validate=True
        )
        assert b'"executed_action":{"move":0' in original
    for row in decisions:
        seat = int(row["seat"])
        round_index = int(row["decision_id"].split("-")[0])
        if round_index == 0 and seat in (3, 5, 7):
            assert (
                row["selected_attempt_id"] is None
                and row["action_status"] == "rejected"
            )
        if round_index == 0 and seat in (0, 4):
            assert row["action_status"] == "accepted"
    native = json.loads(
        (output / "original-native-state.json.bytes")
        .read_bytes()
        .decode("utf-8", "surrogatepass")
    )
    for round_row in native["partial_native_rounds"]:
        assert round_row["native_moves"] == [[0, 0]] * 4
        assert round_row["native_scripted"] == [[False, False]] * 4
    assert native["partial_native_rounds"][1]["native_memos_after"][0] == "stable"
    assert native["partial_native_rounds"][1]["native_memos_after"][1] == "\udc00"
    assert native["partial_native_rounds"][1]["native_memos_after"][2] == "\udc00"
    poisoned_requests = [
        call
        for call in calls
        if call["round"] == 1
        and b"\xed\xb0\x80" in base64.b64decode(call["request_body_b64"])
    ]
    assert len(poisoned_requests) >= 2
    proof = {
        "status": "pass",
        "partial_native_rounds": 2,
        "real_loopback_http_calls": len(calls),
        "forensic_no_target_rows": len(forensic),
        "strict_scalar_JSONL": True,
        "native_commands_unchanged": True,
        "memo_keep_and_next_request_contamination_proven": True,
        "full_server_games": 0,
        "real_provider_calls": 0,
        "elapsed_seconds": elapsed_seconds,
        "trajectory_sha256": hashlib.sha256(raw).hexdigest(),
        "qualification": "actual client, HTTP, native parser/apply, capture and writer; no server pacing or full episode",
    }
    (output / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
    print(json.dumps(proof))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", type=Path)
    parser.add_argument("--verify-existing", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    output = args.output.resolve()
    if args.verify_existing:
        verify(output, json.loads((output / "loopback-http.json").read_text()), None)
        return
    assert args.component is not None
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    initial = [
        b'{"move":0,"note":"first note","memo":"stable"}',
        b'{"move":0,"note":"","memo":"\\udc00"}',
        b'{"move":0,"note":"","memo":"\xed\xb0\x80"}',
        b'{"move":0,"note":"","memo":"","\\udc00":1}',
        b'{"move":0,"note":"","memo":"\\ud83d\\ude03"}',
        b'{"move":0,"note":"","memo":"","\xed\xb0\x80":1}',
        b'{"move":0,"note":"\\udc00","memo":""}',
        b'{"move":0,"note":"","memo":"","extra":"\\udc00"}',
    ]
    calls, errors = [], []
    counts = [0] * 8

    class Sentinel(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                assert self.path == "/v1/messages"
                size = int(self.headers["Content-Length"])
                assert 0 < size <= 131072
                body = self.rfile.read(size)
                slot = int(self.headers["X-Coworld-Player-Slot"])
                index = counts[slot]
                counts[slot] += 1
                assert index < 2
                action = (
                    initial[slot] if index == 0 else b'{"move":0,"note":"","memo":""}'
                )
                # Escape JSON syntax, preserving deliberately invalid raw scalar bytes.
                content = action.replace(b"\\", b"\\\\").replace(b'"', b'\\"')
                response = (
                    b'{"model":"local/ledger-sentinel","content":[{"type":"text","text":"'
                    + content
                    + b'"}],"usage":null}'
                )
                identity = str(uuid.uuid4())
                calls.append(
                    {
                        "slot": slot,
                        "round": index,
                        "call_id": identity,
                        "request_body_b64": base64.b64encode(body).decode(),
                        "response_body_b64": base64.b64encode(response).decode(),
                        "original_action_b64": base64.b64encode(action).decode(),
                    }
                )
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.send_header("X-Softmax-Llm-Call-Id", identity)
                self.end_headers()
                self.wfile.write(response)
            except Exception as error:
                errors.append(repr(error))
                raise

    fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sentinel)
    thread = threading.Thread(target=fixture.serve_forever, daemon=True)
    thread.start()
    env = {
        key: os.environ[key]
        for key in ("PATH", "HOME", "TMPDIR", "LANG")
        if key in os.environ
    }
    env.update(
        COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{fixture.server_port}",
        COWORLD_LLM_MODEL="local/ledger-sentinel",
        COGAME_SAVE_TRAJECTORY_URI=(output / "trajectory.jsonl").as_uri(),
        COWORLD_EPISODE_ID="local-unicode-partial-component",
        COWORLD_GAME_VERSION="local-fixture",
        COWORLD_SOURCE_REVISION="local-fixture",
    )
    (output / "environment-keys.json").write_text(json.dumps(sorted(env)))
    started = time.monotonic()
    try:
        assert shutil.disk_usage(output).free >= 2 * 2**30
        command = [
            str(args.component.resolve()),
            str(output / "original-native-state.json.bytes"),
        ]
        (output / "command.json").write_text(json.dumps(command))
        with (output / "native-component.log").open("xb") as log:
            result = subprocess.run(
                command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=30
            )
        assert result.returncode == 0, result.returncode
        assert not errors and counts == [2] * 8, (errors, counts)
        verify(output, calls, time.monotonic() - started)
    finally:
        fixture.shutdown()
        thread.join(timeout=2)
        (output / "loopback-http.json").write_text(json.dumps(calls, indent=2) + "\n")
        assert (
            sum(path.stat().st_size for path in output.rglob("*") if path.is_file())
            <= 4 * 2**20
        )


if __name__ == "__main__":
    main()
