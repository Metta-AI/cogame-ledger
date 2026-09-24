#!/usr/bin/env bash
set -euo pipefail

mode=${1:?usage: local_episode.sh jev|mirror seed rounds [opponent]}
seed=${2:?seed required}
rounds=${3:?rounds required}
opponent=${4:-mirror}
port=${PORT:-18084}
case "$mode" in
  jev|mirror) ;;
  *) echo "mode must be jev or mirror" >&2; exit 2 ;;
esac
case "$opponent" in
  mirror|shark) ;;
  *) echo "opponent must be mirror or shark" >&2; exit 2 ;;
esac

mkdir -p bin tmp
episode_dir=$(mktemp -d tmp/episode.XXXXXX)
episode_dir="$PWD/$episode_dir"
python3 - "$seed" "$rounds" "$episode_dir/config.json" <<'PY'
import json
import sys
from pathlib import Path
seed, rounds, path = sys.argv[1:]
Path(path).write_text(json.dumps({
    'tokens': [f't{i}' for i in range(8)],
    'players': [{'name': f'P{i}'} for i in range(8)],
    'seed': int(seed), 'rounds': int(rounds),
    'minRoundIntervalMs': 0, 'player_connect_timeout_seconds': 10,
}))
PY
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  nim c --hints:off -o:bin/ledger src/ledger.nim
  nim c --hints:off -o:bin/ledger-player src/ledger_player.nim
fi
bin/ledger --host:127.0.0.1 --port:"$port" \
  --config-path:"$episode_dir/config.json" \
  --results-uri:"file://$episode_dir/results.json" \
  --save-replay-uri:"file://$episode_dir/episode.replay" \
  > "$episode_dir/game.log" 2>&1 &
game=$!
trap 'kill "$game" 2>/dev/null || true' EXIT
sleep 0.5
for slot in 0 1 2 3 4 5 6 7; do
  if [ "$slot" = 0 ] && [ "$mode" = jev ]; then
    COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$port/player?slot=$slot&token=t$slot" \
      PLAYER_JEV=1 bin/ledger-player > "$episode_dir/player$slot.log" 2>&1 &
  else
    scripted="$opponent"
    if [ "$slot" = 0 ]; then scripted=mirror; fi
    COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$port/player?slot=$slot&token=t$slot" \
      PLAYER_SCRIPTED="$scripted" bin/ledger-player \
      > "$episode_dir/player$slot.log" 2>&1 &
  fi
done
wait "$game"
python3 - "$episode_dir" <<'PY'
import json
import re
import sys
from pathlib import Path
path = Path(sys.argv[1])
results = json.loads((path / 'results.json').read_text())
replay = json.loads((path / 'episode.replay').read_text())
log = (path / 'game.log').read_text()
usage = [tuple(map(int, match)) for match in re.findall(
    r'input_tokens (\d+) output_tokens (\d+)', log)]
seat0_scripted = sum(
    event['scriptedA'] if event['seat'] == 0 else event['scriptedB']
    for event in replay['events']
    if event['kind'] == 'meeting' and 0 in (event['seat'], event['other'])
)
print(json.dumps({
    'artifacts': str(path), 'rounds': results['rounds'],
    'seat0_score': results['scores'][0], 'seat0_total': results['total'][0],
    'jev_calls': len(usage), 'input_tokens': sum(item[0] for item in usage),
    'output_tokens': sum(item[1] for item in usage),
    'seat0_scripted_meetings': seat0_scripted,
}))
PY
