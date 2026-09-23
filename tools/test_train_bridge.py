"""Exercise both certified Ledger variants through Metta's numeric protocol."""

import json
import sys
from pathlib import Path

from metta_training.decision_environment import DecisionEncoding
from metta_training.game import Terminal
from metta_training.session import GameBridge


BRIDGE = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"

for variant, rounds in (("standard", 14), ("quickfire", 7)):
    for seed in ("test-1", "test-2"):
        with GameBridge([str(BRIDGE), str(MANIFEST), variant]) as bridge:
            observation = bridge.reset(seed, 8)
            decisions = 0
            frozen = observation.semantic_view["history"]
            while not isinstance(observation, Terminal):
                assert observation.semantic_view["history"] == frozen
                encoding = DecisionEncoding.model_validate_json(
                    bridge.request({"kind": "encode"})
                )
                assert len(encoding.values) == 187
                assert len(encoding.actions) == 101
                action = json.loads(bridge.teacher())
                assert encoding.action_for(encoding.indices_for(action)) == action
                observation = bridge.step(
                    observation.decision_id, json.dumps(action)
                ).observation
                decisions += 1
                if not isinstance(observation, Terminal) and decisions % 8 == 0:
                    frozen = observation.semantic_view["history"]
            assert decisions == rounds * 8
            assert all(score >= 0 for score in observation.scores.values())
            print(variant, seed, decisions, observation.scores)
