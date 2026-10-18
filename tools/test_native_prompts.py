"""Play a complete published episode through eight players and real HTTP calls."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

ROOT = Path(__file__).resolve().parents[1]


class Fixture(ThreadingHTTPServer):
    mode: str
    requests: list
    seen: set


class Handler(BaseHTTPRequestHandler):
    server: Fixture

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        request = json.loads(body)
        seat = int(self.headers["X-Coworld-Player-Slot"])
        user = request["messages"][0]["content"]
        round_number = int(user.split()[1])
        key = (round_number, seat)
        reply = json.dumps(
            {"move": 999, "note": "fixture café", "memo": f"private-{seat}"}
        )
        if self.server.mode == "rejected" or (
            self.server.mode == "retry" and key not in self.server.seen
        ):
            reply = "invalid fixture reply"
        self.server.seen.add(key)
        response = json.dumps({"content": [{"type": "text", "text": reply}]}).encode()
        self.server.requests.append((body, response.decode()))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("verifier", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--variant", choices=("standard", "quickfire"), default="quickfire"
    )
    parser.add_argument("--wording", default="canonical")
    parser.add_argument(
        "--mode", choices=("accepted", "retry", "rejected"), default="accepted"
    )
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
    config = next(
        v["game_config"] for v in manifest["variants"] if v["id"] == args.variant
    )
    config.update(
        seed=7,
        promptVariant=args.wording,
        promptSeed=3,
        tokens=[f"t{i}" for i in range(8)],
    )
    (output / "config.json").write_text(json.dumps(config))
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    fixture = Fixture(("127.0.0.1", 0), Handler)
    fixture.mode, fixture.requests, fixture.seen = args.mode, [], set()
    thread = Thread(target=fixture.serve_forever, daemon=True)
    thread.start()
    env = {
        **os.environ,
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
        "LEDGER_CAPTURE_DIR": str(output / "private"),
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{fixture.server_port}",
        "COWORLD_LLM_MODEL": "fixture/validation",
        "PLAYER_PROMPT": "Maximize your median per-meeting payoff.",
        "PLAYER_SCRIPTED": "",
    }
    processes, logs = [], []
    try:
        log = (output / "game.log").open("w")
        logs.append(log)
        processes.append(
            subprocess.Popen([args.game], cwd=ROOT, env=env, stdout=log, stderr=log)
        )
        for _ in range(400):
            assert processes[0].poll() is None, (output / "game.log").read_text()
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            time.sleep(0.025)
        else:
            raise AssertionError("game listener did not start")
        for seat in range(8):
            log = (output / f"player-{seat}.log").open("w")
            logs.append(log)
            player_env = {
                **env,
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
            }
            processes.append(
                subprocess.Popen(
                    [args.player], cwd=ROOT, env=player_env, stdout=log, stderr=log
                )
            )
        for process in processes:
            assert process.wait(timeout=800) == 0, output
        result = json.loads((output / "results.json").read_text())
        assert result["reason"] == "complete" and result["rounds"] == config["rounds"]
        trace = output / "private/host.jsonl"
        events = [json.loads(line) for line in trace.read_text().splitlines()]
        assert trace.stat().st_mode & 0o777 == 0o600
        assert (
            events[0]["source_revision"] == revision and not events[0]["source_dirty"]
        )
        assert events[-1]["result"] == result
        resolved = [e for e in events if e["event_type"] == "decision_resolved"]
        assert len(resolved) == config["rounds"] * 8
        replay = json.loads((output / "replay.json").read_text())
        applied = [e["event"] for e in events if e["event_type"] == "action_applied"]
        assert applied == [
            e for e in replay["events"] if e["kind"] not in ("start", "round")
        ]
        wire = list(fixture.requests)
        selected = "questions" if args.wording == "mixed" else args.wording
        for row in resolved:
            assert row["prompt_selection"]["variant"] == selected
            assert len(row["attempts"]) == (1 if args.mode == "accepted" else 2)
            for index, attempt in enumerate(row["attempts"]):
                pair = (attempt["request_body"], attempt["response_body"])
                wire.remove(pair)
                request = json.loads(attempt["request_body"])
                metadata = attempt["prompt_template"]
                assert (
                    metadata["variant"] == selected
                    and metadata["bank"] == "ledger-rules-v1"
                )
                for role, text in (
                    ("system", request["system"]),
                    ("user", request["messages"][0]["content"]),
                ):
                    assert (
                        metadata[role + "_sha256"]
                        == hashlib.sha256(text.encode()).hexdigest()
                    )
                assert attempt["accepted"] == (
                    args.mode == "accepted" or args.mode == "retry" and index == 1
                )
            assert row["scripted"] == (args.mode == "rejected")
            if args.mode != "rejected":
                assert row["resolved_action"] == row["attempts"][-1]["parsed_action"]
                assert row["resolved_action"]["memo"] == f"private-{row['seat']}"
            meeting = next(
                e
                for e in applied
                if e["kind"] == "meeting"
                and e["round"] == row["round"]
                and row["seat"] in (e["seat"], e["other"])
            )
            side = "A" if meeting["seat"] == row["seat"] else "B"
            assert meeting["move" + side] == row["resolved_action"]["move"]
        assert not wire
        subprocess.run([args.verifier, output / "replay.json"], cwd=ROOT, check=True)
        print(
            args.variant, args.wording, args.mode, "full native game PASS", flush=True
        )
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
        for log in logs:
            log.close()
        fixture.shutdown()
        fixture.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    main()
