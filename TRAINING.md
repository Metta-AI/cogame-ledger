# Ledger training

Ledger has a local simulator and hosted text players. Export complete games for
Metta post-training with the same per-seat prompts and reply parser as the
hosted player:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/ledger-standard 10 1 standard
nim r --path:src tools/export_posttrain.nim /tmp/ledger-quickfire 10 1 quickfire
```

The exporter reads each certified `game_config` from
`coworld_manifest_template.json`, runs ten seeded games per variant, and writes
`train.jsonl`, `validation.jsonl`, and `manifest.json`. Seeds divisible by five
go to validation, keeping each game entirely in one split. The published
mirror and shark scripts alternate by seat. Each reply passes through the
hosted parser and resolves through the native simulator. The exporter refuses
an existing output directory.

Train the text policy with Metta's post-training CLI:

```bash
uv run python -m metta_posttrain.train --dataset /tmp/ledger-standard \
  --output /tmp/ledger-model --model Qwen/Qwen2.5-0.5B-Instruct \
  --max-steps 100 --max-length 4096
```

The dataset is imitation of scripted play; its loss does not measure policy
quality.

# Numeric reinforcement learning

Compile the persistent bridge and pass its manifest and variant to Metta's
`recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nim c -d:release --path:src -o:/tmp/ledger-train-bridge tools/train_bridge.nim
python tools/test_train_bridge.py /tmp/ledger-train-bridge
```

Both certified variants expose 187 numeric observation values and 101 fixed
move slots. The simulator's role-specific legal range masks invalid moves.
Observations contain current public meetings, resolved history, payoffs, and
conduct tallies. Decisions are frozen until all eight seats choose. The
numeric policy sends no free-form notes or memos; the hosted prompts and
post-training exporter retain that channel. Even seats use the `mirror`
teacher and odd seats use `shark`. Complete games return native median-payoff
scores.
