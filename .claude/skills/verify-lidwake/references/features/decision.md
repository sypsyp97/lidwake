# Decision loop

Each tick evaluates inputs and decides hold or release. Dry runs print `tick k: hold=<bool> reason=<reason>`.

## Sub-features
- forced: `lidwake on` ⇒ reason `forced`.
- settling: after activity stops, hold for 300 s (`reason=settling`), then `idle`.
- clock moved back (SPEC §1 rule 0): a stored `lastActive` later than now counts as now; the saved value is corrected to now.
- battery low (< 20 % on battery) overrides everything.

## How to reach it
`lidwake run --dry-run --ticks N --interval S`, `lidwake status`, `lidwake on|off`.

## Driving it
```bash
LW on; LW run --dry-run --ticks 1 --interval 0.05      # tick 1: hold=true reason=forced
LW off
# clock moved back: lastActive one year ahead (Foundation reference-date seconds)
FUT=$(( $(date +%s) + 31536000 - 978307200 ))
mkdir -p "$ISO/state/dry-run"; printf '{"owned":false,"lastActive":%s}' $FUT > "$ISO/state/dry-run/journal.json"
LW run --dry-run --ticks 1 --interval 0.05      # idle inputs: hold=true reason=settling
python3 -c 'import json,sys,time; j=json.load(open(sys.argv[1])); print(j["lastActive"]+978307200-time.time())' "$ISO/state/dry-run/journal.json"
# prints a value <= 0 (corrected to the tick time), not ~31536000
```

## State
| location | lifetime | writers | readers | reset trigger | round-trip check |
|---|---|---|---|---|---|
| `journal.json` `lastActive` | disk | each tick (Decision result) | next tick, `status` | activity sets it to now | `LW status` decision line after the dry run |
| `<state>/force` | disk, survives reboot by design | `lidwake on/off` | every tick | `lidwake off` | `LW status` prints `forced: true` |

## Gotchas
- Any open Claude Code task output file under `/private/tmp/claude-<uid>/` makes inputs active (`backgroundTask`); idle scenarios need none open. The Bash tool of Claude Code itself holds one, so drive idle scenarios from a plain terminal.
- Active inputs set `lastActive` to now on every tick, so they cannot show the clock rule; only idle inputs can.
- On battery below 20 % every tick reads `batteryLow`.
- `status` evaluates with the real time and the stored `lastActive`; `run` corrects and saves it.
