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
quality. Ledger's numeric meeting moves could support a discrete RL codec, but
its prompt policy also carries free-form notes and memos. The current Metta RL
and PufferLib bridges do not expose Ledger's meeting action and observation.
