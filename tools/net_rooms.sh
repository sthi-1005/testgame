#!/bin/bash
# Rooms on one dedicated WebSocket server: party ABCD (3 players), party WXYZ (2 players, another
# stage), and a join with a code that doesn't exist. Prints the server log and each bot's summary.
#   tools/net_rooms.sh [seconds]       GODOT=/path/to/godot to override the binary
cd "$(dirname "$0")/.."
G=${GODOT:-godot}
SECS=${1:-30}
OUT=$(mktemp -d)
S="--server-url ws://127.0.0.1:24565"
N=0
bot() { N=$((N + 1)); timeout $((SECS + 10)) "$G" --headless --path . res://tools/net_bot.tscn -- --secs "$SECS" $S "$@" > "$OUT/bot$N.log" 2>&1 & sleep 0.4; }
timeout $((SECS + 15)) "$G" --headless --path . res://net/server.tscn -- --ws > "$OUT/server.log" 2>&1 &
sleep 2
bot --create --room ABCD --cls sellsword --wait 3
bot --room ABCD --cls cleric
bot --room ABCD --cls mage
STAGE=$(grep -o '"id": *"[a-z_]*"' stages/stages.gd | sed -n 2p | grep -o '"[a-z_]*"$' | tr -d '"')
bot --create --room WXYZ --cls mage --wait 2 --stage "${STAGE:-saltrock}"
bot --room WXYZ --cls sellsword
bot --room QQQQ --cls cleric
wait
grep -E "^Net|^Saltrock|SCRIPT ERROR" "$OUT/server.log"
grep -h -E "^BOT|SCRIPT ERROR|No party" "$OUT"/*.log | grep -v "^Net"
echo "logs: $OUT"
