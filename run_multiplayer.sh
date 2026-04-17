#!/usr/bin/env bash
# Launch the split-screen 2-player dino game.
# One window, two SubViewports, two hand-tracked players (left half of
# camera = P1, right half = P2).
#
# Usage:  ./run_multiplayer.sh
# Requires: Godot.app in /Applications or ~/Downloads.

set -e

GODOT_APP=""
for path in \
  "/Applications/Godot.app" \
  "$HOME/Downloads/Godot.app"; do
  if [ -d "$path" ]; then
    GODOT_APP="$path"; break
  fi
done

if [ -z "$GODOT_APP" ]; then
  echo "Could not find Godot.app. Edit this script to set GODOT_APP=<path>."
  exit 1
fi

PROJECT="$(cd "$(dirname "$0")" && pwd)/game"
echo "Project: $PROJECT"
echo "Godot:   $GODOT_APP"
echo

open -n -a "$GODOT_APP" --args \
  --path "$PROJECT" \
  --resolution 1280x720

cat <<'EOF'

Split-screen launched.

Player 1 (LEFT half of screen):
  ← / →     switch lanes
  ↑         jump
  /         shoot

Player 2 (RIGHT half of screen):
  A / D     switch lanes
  W         jump
  F         shoot

Hand tracker (one webcam, both players):
  Left half of camera frame  → P1
  Right half of camera frame → P2
  Swipe left/right → switch lanes
  Swipe up         → jump
  👉 gun sign       → shoot

Shared:
  R         restart after game over

EOF
