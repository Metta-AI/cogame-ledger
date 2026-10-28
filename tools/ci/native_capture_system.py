"""Exercise the full ordinary Ledger game with eight native players and local HTTP."""

import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
import uuid
from pathlib import Path

from websockets.sync.client import connect
from websockets.exceptions import ConnectionClosed


def fixture_reply(case, round_index, slot, attempt, request):
    """Prospectively fixed negative controls; these are never teacher labels."""
    text = '{"move":0,"note":"","memo":""}'
    status, padding, extra_headers = 200, "", {}
    if case != "adversarial":
        return text, status, padding, extra_headers
    if round_index == 0:
        text = json.dumps(
            {"move": 0, "note": f"discard-first-{slot}", "memo": f"memo-{slot}"}
        )
    elif round_index == 1:
        text = json.dumps({"move": 0, "note": f"review-{slot}", "memo": ""})
    elif round_index == 2:
        move = (
            "cooperate"
            if '"move" is "cooperate" or "defect"' in request["messages"][0]["content"]
            else 0
        )
        text = "```json\n" + json.dumps({"move": move}) + "\n```"
    elif round_index == 3:
        text = [
            '{"move":"0"}',
            '{"move":0.0}',
            '{"move":"0 coins"}',
            '{"move":999}',
            '{"move":0,"note":"  trimmed  "}',
            '{"move":0,"memo":"  trimmed  "}',
            json.dumps({"move": 0, "note": "n" * 121}),
            json.dumps({"move": 0, "memo": "m" * 401}),
        ][slot]
    elif round_index == 4 and attempt == 0:
        text = [
            '{"move":0,"extra":1}',
            '{"move":0,"move":0}',
            '{"move":0,"extra":NaN}',
            '{\v"move":0}',
            '{"move":0/* native-tolerated comment */}',
            '{"move":0,"note":null}',
            '{"move":0,"memo":false}',
            '{"move":0,"note":42}',
        ][slot]
    elif round_index == 5:
        if slot == 0 and attempt == 0:
            status = 500
        elif slot == 1 and attempt == 0 or slot == 2:
            text = "{}"
        elif slot == 3:
            padding = "p" * 40000
        elif slot == 4:
            extra_headers = {"X-Request-Id": "h" * 5000}
        elif slot == 6 and attempt == 0:
            text = "not JSON"
        elif slot == 7 and attempt == 0:
            text = "{}"
    elif round_index == 12 and slot == 0 and attempt == 0:
        status = 429
    return text, status, padding, extra_headers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--player", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--case", choices=("ordinary", "off", "adversarial"), default="ordinary"
    )
    args = parser.parse_args()
    os.umask(0o077)
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = json.loads(Path("coworld_manifest_template.json").read_text())
    config = next(
        v["game_config"] for v in manifest["variants"] if v["id"] == "standard"
    ).copy()
    config.update(seed=1, tokens=[f"local-ledger-{i}" for i in range(8)])
    assert config["rounds"] == 14 and config["minRoundIntervalMs"] == 20000
    (output / "config.json").write_text(json.dumps(config))
    (output / "frozen-fixture-source.py").write_bytes(Path(__file__).read_bytes())
    calls, errors = [], []
    attempt_counts = {}
    requests_log = (output / "loopback-http.jsonl").open("w")
    lock = threading.Lock()

    class Sentinel(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                assert self.path == "/v1/messages"
                size = int(self.headers["Content-Length"])
                assert 0 < size <= 131072
                body = self.rfile.read(size)
                request = json.loads(body)
                slot = int(self.headers["X-Coworld-Player-Slot"])
                assert 0 <= slot < 8
                assert request["model"] == "local/ledger-sentinel"
                assert request["max_tokens"] == 900
                assert (
                    f"local-ledger-operator-{slot}" in request["messages"][0]["content"]
                )
                round_index = (
                    int(
                        re.search(
                            r"Round (\d+) of", request["messages"][0]["content"]
                        ).group(1)
                    )
                    - 1
                )
                attempt_index = attempt_counts.get((round_index, slot), 0)
                attempt_counts[round_index, slot] = attempt_index + 1
                text, status, padding, extra_headers = fixture_reply(
                    args.case, round_index, slot, attempt_index, request
                )
                identity = str(uuid.uuid4())
                response = json.dumps(
                    {
                        "id": identity,
                        "model": "local/ledger-sentinel",
                        "content": [{"type": "text", "text": text}],
                        "stop_reason": "end_turn",
                        "usage": {"input_tokens": 1, "output_tokens": 1},
                        "fixture_padding": padding,
                    }
                ).encode()
                item = {
                    "id": identity,
                    "slot": slot,
                    "round": round_index,
                    "attempt_index": attempt_index,
                    "status": status,
                    "original_text": text,
                    "request_started_monotonic": time.monotonic(),
                    "request_body": body.decode(),
                    "response_body": response.decode(),
                }
                with lock:
                    assert len(calls) < 224
                    calls.append(item)
                time.sleep(0.1)
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.send_header("X-Softmax-Llm-Call-Id", identity)
                for key, value in extra_headers.items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(response)
                item["response_finished_monotonic"] = time.monotonic()
                with lock:
                    requests_log.write(json.dumps(item) + "\n")
                    requests_log.flush()
            except Exception as error:
                errors.append(repr(error))
                raise

    fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sentinel)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    clean = {
        k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ
    }
    with socket.socket() as available:
        available.bind(("127.0.0.1", 0))
        port = available.getsockname()[1]
    env = clean | {
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
        "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
        "COWORLD_EPISODE_ID": "local-ledger-full-native-fixture",
        "COWORLD_GAME_VERSION": "local-system-fixture",
        "COWORLD_SOURCE_REVISION": "local-system-fixture",
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{fixture.server_port}",
        "COWORLD_LLM_MODEL": "local/ledger-sentinel",
    }
    if args.case == "off":
        env.pop("COGAME_SAVE_TRAJECTORY_URI")
    (output / "environment-keys.json").write_text(
        json.dumps({"parent": sorted(clean), "game": sorted(env)}, indent=2)
    )
    processes, logs = [], []
    started = time.monotonic()
    measurements = (output / "resources.jsonl").open("w")
    public = {
        "messages": 0,
        "first": None,
        "last": None,
        "final": None,
        "closure": None,
        "errors": [],
        "pings": [],
    }
    stop_reader = threading.Event()
    public_trace = (output / "public-ws.jsonl").open("x")
    try:
        log = (output / "game.log").open("w")
        logs.append(log)
        game = subprocess.Popen(
            [str(args.game.resolve())], env=env, stdout=log, stderr=subprocess.STDOUT
        )
        processes.append(game)
        while True:
            assert game.poll() is None, "game exited before HTTP readiness"
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/healthz", timeout=1
                ) as reply:
                    assert reply.status == 200
                break
            except OSError:
                assert time.monotonic() - started < 20
                time.sleep(0.05)
        with connect(f"ws://127.0.0.1:{port}/global", open_timeout=3) as viewer:
            first = json.loads(viewer.recv(timeout=3))
            assert first["type"] == "state" and first["game"] == "ledger"
            assert viewer.ping(b"local-before-model").wait(timeout=3)
            public.update(messages=1, first=first, last=first)
            public_trace.write(
                json.dumps(
                    {"elapsed_seconds": time.monotonic() - started, "payload": first}
                )
                + "\n"
            )

            def drain_public():
                previous = time.monotonic()
                try:
                    while not stop_reader.is_set():
                        try:
                            payload = json.loads(viewer.recv(timeout=2))
                        except TimeoutError:
                            continue
                        now = time.monotonic()
                        public["messages"] += 1
                        public["last"] = payload
                        if payload.get("done") or payload.get("type") == "final":
                            public["final"] = payload
                        public_trace.write(
                            json.dumps(
                                {
                                    "elapsed_seconds": now - started,
                                    "seconds_since_previous": now - previous,
                                    "payload": payload,
                                }
                            )
                            + "\n"
                        )
                        public_trace.flush()
                        previous = now
                except ConnectionClosed as error:
                    public["closure"] = str(error)
                    # The native process exits after its final-state grace.
                    # A closure before final state remains a real proof failure.
                    if public["final"] is None:
                        public["errors"].append(str(error))
                except Exception as error:
                    public["errors"].append(repr(error))

            reader = threading.Thread(target=drain_public, daemon=True)
            reader.start()
            last_ping = time.monotonic()
            for slot in range(8):
                player_env = clean | {
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={slot}&token=local-ledger-{slot}",
                    "PLAYER_PROMPT": f"local-ledger-operator-{slot}",
                }
                log = (output / f"player-{slot}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen(
                        [str(args.player.resolve())],
                        env=player_env,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                )
            while game.poll() is None:
                elapsed = time.monotonic() - started
                size = sum(p.stat().st_size for p in output.rglob("*") if p.is_file())
                free = shutil.disk_usage(output).free
                assert elapsed < 360 and size < 128 * 2**20 and free >= 2 * 2**30
                if public["final"] is None and time.monotonic() - last_ping >= 20:
                    ping_started = time.monotonic()
                    assert viewer.ping(b"local-throughout-model").wait(timeout=3)
                    public["pings"].append(
                        {
                            "elapsed_seconds": ping_started - started,
                            "round_trip_seconds": time.monotonic() - ping_started,
                        }
                    )
                    last_ping = time.monotonic()
                assert not public["errors"], public["errors"]
                measurements.write(
                    json.dumps(
                        {
                            "elapsed_seconds": elapsed,
                            "fixture_http_calls": len(calls),
                            "retained_bytes": size,
                            "free_bytes": free,
                            "public_frames_drained": public["messages"],
                            "public_pongs": len(public["pings"]),
                        }
                    )
                    + "\n"
                )
                measurements.flush()
                time.sleep(1)
            assert game.returncode == 0
            stop_reader.set()
            reader.join(timeout=3)
            assert not reader.is_alive() and not public["errors"], public
            assert public["final"] is not None, (
                "whole-episode final public state missing"
            )
        for process in processes[1:]:
            assert process.wait(timeout=10) == 0
        result = json.loads((output / "results.json").read_text())
        assert result["reason"] == "complete" and result["rounds"] == 14, result
        assert not errors and 112 <= len(calls) <= 224, (errors, len(calls))
        for round_index in range(14):
            assert {
                c["slot"]
                for c in calls
                if c["round"] == round_index and c["attempt_index"] == 0
            } == set(range(8))
        if args.case != "adversarial":
            assert len(calls) == 112
        replay = (output / "replay.json").read_bytes()
        assert (
            b"local-ledger-operator-" not in replay
            and b"X-Softmax-Llm-Call-Id" not in replay
        )
        proof = {
            "native_rounds": 14,
            "native_decisions": 112,
            "fixture_http_calls": len(calls),
            "real_provider_calls": 0,
            "native_min_round_interval_ms": 20000,
            "elapsed_seconds": time.monotonic() - started,
            "replay_sha256": hashlib.sha256(replay).hexdigest(),
            "clocks_unchanged": True,
            "synthetic_teacher_targets": 0,
            "whole_episode_public_frames": public["messages"],
            "whole_episode_pongs": len(public["pings"]),
            "final_public_state_seen": public["final"] is not None,
        }
        (output / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
        if args.case == "off":
            assert not (output / "trajectory.jsonl").exists()
            print(json.dumps(proof))
            return
        assert (output / "trajectory.jsonl").is_file(), (
            "complete native game omitted requested private capture"
        )
        rows = [
            json.loads(line)
            for line in (output / "trajectory.jsonl").read_text().splitlines()
        ]
        decisions = [row for row in rows if "action_status" in row]
        assert len(decisions) == 112
        by_id = {call["id"]: call for call in calls}
        accepted = rejected = fallback = 0
        for row in decisions:
            if row["action_status"] == "accepted":
                accepted += 1
            elif row["action_status"] == "fallback":
                fallback += 1
            else:
                rejected += 1
            diagnostics = row["observation"]["attempt_diagnostics"]
            for index, attempt in enumerate(row["attempts"]):
                if attempt["origin"] != "model":
                    continue
                if attempt["platform_call_id"] is not None:
                    call = by_id[attempt["platform_call_id"]]
                else:
                    call = next(
                        c
                        for c in calls
                        if c["round"] == int(row["decision_id"].split("-")[0])
                        and c["slot"] == int(row["seat"])
                        and c["attempt_index"] == index
                    )
                assert int(row["seat"]) == call["slot"]
                assert (
                    base64.b64decode(diagnostics[index]["request_body_b64"])
                    == call["request_body"].encode()
                )
                if attempt["response_body_b64"] is not None:
                    assert (
                        base64.b64decode(attempt["response_body_b64"])
                        == call["response_body"].encode()
                    )
                if attempt["response"] is not None:
                    assert attempt["response"] == call["original_text"]
                if (
                    args.case == "adversarial"
                    and call["round"] in (3, 4)
                    and call["attempt_index"] == 0
                ):
                    assert not attempt["accepted"], (
                        row["decision_id"],
                        call["original_text"],
                    )
            if args.case == "ordinary":
                assert row["action_status"] == "accepted" and row[
                    "executed_action"
                ] == {"move": 0, "note": "", "memo": ""}
                assert len(row["attempts"]) == 1
                assert (
                    row["attempts"][0]["accepted"]
                    and row["selected_attempt_id"] == row["attempts"][0]["attempt_id"]
                )
        if args.case == "adversarial":
            assert fallback == 1 and rejected >= 10
            assert any(c["status"] == 429 for c in calls) and any(
                c["status"] == 500 for c in calls
            )
            assert len(calls) > 112
        proof.update(
            exact_raw_applied_accepted=accepted,
            rejected=rejected,
            native_fallback=fallback,
            fixture_case=args.case,
        )
        (output / "proof.json").write_text(json.dumps(proof, indent=2) + "\n")
        print(json.dumps(proof))
    finally:
        stop_reader.set()
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        fixture.shutdown()
        public_trace.close()
        (output / "public-ws-summary.json").write_text(
            json.dumps(public, indent=2) + "\n"
        )
        measurements.close()
        requests_log.close()
        for log in logs:
            log.close()


if __name__ == "__main__":
    main()
