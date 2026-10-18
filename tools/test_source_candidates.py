"""Qualify complete source games across both published variants and training wording."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
exporter, verifier = map(Path, sys.argv[1:])
families = set()
with tempfile.TemporaryDirectory(prefix="ledger-source-") as directory:
    root = Path(directory)
    for variant in ("standard", "quickfire"):
        reference = None
        for wording in ("canonical", "plain", "numbered", "questions", "reordered"):
            output = root / variant / wording
            subprocess.run(
                [exporter, output, "10", "1", variant, wording, "0"],
                cwd=ROOT,
                check=True,
            )
            manifest = json.loads((output / "manifest.json").read_text())
            assert manifest["review_required"] and len(manifest["runs"]) == 10
            comparable = []
            for run in manifest["runs"]:
                source = output / run["trajectory"]
                assert source.stat().st_mode & 0o777 == 0o600
                records = [json.loads(line) for line in source.read_text().splitlines()]
                episode = records[-1]
                assert (
                    episode["event_type"] == "episode"
                    and episode["status"] == "completed"
                )
                families.add(episode["seed_family"])
                assert (
                    len(records) - 1
                    == run["decisions"]
                    == (14 if variant == "standard" else 7) * 8
                )
                replay_path = output / run["replay"]
                subprocess.run([verifier, replay_path], cwd=ROOT, check=True)
                replay = json.loads(replay_path.read_text())
                meetings = {}
                for event in replay["events"]:
                    if event["kind"] == "meeting":
                        meetings[event["round"], event["seat"]] = event["moveA"]
                        meetings[event["round"], event["other"]] = event["moveB"]
                for decision in records[:-1]:
                    (attempt,) = decision["attempts"]
                    view = decision["observation"]["view"]
                    action = decision["executed_action"]
                    assert (
                        action
                        == attempt["parsed_action"]
                        == {
                            "move": meetings[view["round"], int(decision["seat"])],
                            "note": "",
                            "memo": "",
                        }
                    )
                    metadata = decision["observation"]["prompt_template"]
                    assert metadata["variant"] == wording
                    for role, index in (("system", 0), ("user", 1)):
                        assert (
                            metadata[role + "_sha256"]
                            == hashlib.sha256(
                                attempt["prompt"][index]["content"].encode()
                            ).hexdigest()
                        )
                    assert (
                        attempt["request"] is None
                        and attempt["platform_call_id"] is None
                    )
                    comparable.append((view, attempt["prompt"][1], action))
                comparable.append(episode["outcome"])
            if reference is None:
                reference = comparable
            else:
                assert comparable == reference
        for heldout in ("heldout-briefing", "heldout-reference"):
            output = root / variant / heldout
            result = subprocess.run(
                [exporter, output, "10", "1", variant, heldout, "0"],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            assert (
                result.returncode
                and "held-out wording is evaluation only" in result.stderr
            )
            assert not output.exists()
assert len(families) == 10
print(
    "100 complete source games, replay checks, ten seed families and held-out rejection PASS"
)
