#!/bin/bash
# Dedicated server + 5 headless bot clients on localhost. Prints the server's bandwidth lines and each bot's summary.
#   tools/net_party.sh [seconds]       GODOT=/path/to/godot to override the binary
#   LAG="60 15 0.03" tools/net_party.sh   routes clients through tools/lagproxy.py (120 ms ping, 3% loss)
cd "$(dirname "$0")/.."
G=${GODOT:-godot}
SECS=${1:-60}
PORT=24565
if [ -n "$LAG" ]; then  # LAG="60 15 0.03": one-way delay ms, jitter ms, loss
  set -- $LAG
  timeout $((SECS + 15)) python3 tools/lagproxy.py --listen 24566 --target 24565 --delay "$1" --jitter "$2" --loss "$3" &
  PORT=24566
fi
OUT=$(mktemp -d)
timeout $((SECS + 15)) "$G" --headless --path . res://net/server.tscn -- --port 24565 > "$OUT/server.log" 2>&1 &
sleep 2
i=0
for c in sellsword cleric mage mage sellsword; do
  i=$((i + 1))
  timeout $((SECS + 10)) "$G" --headless --path . res://tools/net_bot.tscn -- --join 127.0.0.1:$PORT --cls $c --wait 5 --secs "$SECS" > "$OUT/c$i.log" 2>&1 &
  sleep 0.3
done
wait
grep -E "^Net|^Saltrock|SCRIPT ERROR" "$OUT/server.log"
grep -h -E "^BOT|SCRIPT ERROR" "$OUT"/c*.log
echo "logs: $OUT"
