#!/usr/bin/env bash
# Launch two Godot windows side-by-side: one hosts, one joins 127.0.0.1.
# Usage:  ./run_multiplayer.sh
# Requires: Godot.app in /Applications or ~/Downloads.

set -e

GODOT=""
for path in \
  "/Applications/Godot.app/Contents/MacOS/Godot" \
  "$HOME/Downloads/Godot.app/Contents/MacOS/Godot"; do
  if [ -x "$path" ]; then
    GODOT="$path"; break
  fi
done

if [ -z "$GODOT" ]; then
  echo "Could not find Godot.app. Edit this script to set GODOT=<path>."
  exit 1
fi

PROJECT="$(cd "$(dirname "$0")" && pwd)/game"
echo "Project: $PROJECT"
echo "Godot:   $GODOT"
echo

cd "$PROJECT"

echo "Starting HOST on the left…"
"$GODOT" --position 50,80 --resolution 900x600 -- --host \
  > /tmp/dino_host.log 2>&1 &
HOST_PID=$!

sleep 2
echo "Starting CLIENT on the right…"
"$GODOT" --position 980,80 --resolution 900x600 -- --join=127.0.0.1 \
  > /tmp/dino_client.log 2>&1 &
CLIENT_PID=$!

echo
echo "Both windows launched."
echo "  Host PID:   $HOST_PID"
echo "  Client PID: $CLIENT_PID"
echo "  Logs:       /tmp/dino_host.log, /tmp/dino_client.log"
echo
echo "Controls (in each window):"
echo "  ← / →   switch lanes"
echo "  SPACE   jump"
echo "  A       shoot (destroys bird in your lane, spawns one in the other window)"
echo "  R       restart after game over"
echo
echo "Close either window to stop. Ctrl-C here to keep them but detach."
wait
