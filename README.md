# 3D Dino Endless Runner

A 3D endless runner game (Godot 4) controlled by hand gestures via webcam (Python + MediaPipe). The two systems communicate over UDP on localhost.

## Prerequisites

- **Godot 4.x** (GDScript)
- **Python 3.10+**
- **Webcam** (for hand gesture control)

## Setup

### Hand Tracker

```bash
cd hand_tracker
pip install -r requirements.txt
```

### Game

Open the `game/` folder in Godot 4 as a project.

## Running

### Terminal 1 — Hand Tracker

```bash
python hand_tracker/hand_tracker.py
```

Optional flags:
- `--port 6789` — UDP port (default: 6789)
- `--threshold 0.15` — Swipe sensitivity (default: 0.15)
- `--cooldown 0.4` — Seconds between gestures (default: 0.4)
- `--camera 0` — Webcam index (default: 0)

### Terminal 2 — Godot Game

Run the project from the Godot editor (press Play) or from the command line.

Keyboard fallback works without the Python script running.

## Controls

| Action | Hand Gesture | Keyboard |
|---|---|---|
| Move left | Swipe left | Left arrow / A |
| Move right | Swipe right | Right arrow / D |
| Jump | Swipe up | Space / Up arrow |
| Restart | Swipe up | R |

## How It Works

- The Python script captures webcam frames, runs MediaPipe hand detection, and tracks the index finger tip position.
- When a swipe gesture is detected (movement exceeding the threshold within a short time window), it sends a UDP message (`swipe_left`, `swipe_right`, or `swipe_up`) to `127.0.0.1:6789`.
- The Godot game listens on that UDP port and translates gestures into player actions (lane switch or jump).
