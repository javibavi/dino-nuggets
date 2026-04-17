#!/usr/bin/env python3
"""Hand gesture tracker for 3D Dino Runner.

Uses MediaPipe HandLandmarker (tasks API, VIDEO mode) to detect swipe
gestures from a webcam and sends them to the Godot game over UDP.
"""

import argparse
import os
import socket
import ssl
import time
import urllib.request
from collections import deque

import cv2
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision

MODEL_URL = "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task"
MODEL_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hand_landmarker.task")
FRAME_PATH = "/tmp/hand_tracker_frame.jpg"


def download_model():
    if os.path.exists(MODEL_PATH):
        return
    print(f"Downloading hand landmarker model...")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.urlopen(MODEL_URL, context=ctx)
    with open(MODEL_PATH, "wb") as f:
        f.write(req.read())
    print("Model downloaded.")


def parse_args():
    parser = argparse.ArgumentParser(description="Hand gesture tracker")
    parser.add_argument("--port", type=int, default=6789)
    parser.add_argument("--threshold", type=float, default=0.07)
    parser.add_argument("--cooldown", type=float, default=0.5)
    parser.add_argument("--camera", type=int, default=0)
    return parser.parse_args()


def get_palm_center(landmarks):
    """Average of wrist + finger bases for stable palm center."""
    pts = [landmarks[i] for i in (0, 5, 9, 13, 17)]
    return (
        sum(p.x for p in pts) / 5,
        sum(p.y for p in pts) / 5,
    )


def _dist(a, b):
    return ((a.x - b.x) ** 2 + (a.y - b.y) ** 2 + (a.z - b.z) ** 2) ** 0.5


def is_gun_sign(landmarks) -> bool:
    """Detect a 'gun' hand pose: index + thumb extended, other fingers folded.

    Uses tip-to-wrist vs PIP-to-wrist distance to decide if a finger is
    extended (palm orientation independent).
    """
    wrist = landmarks[0]
    # Per-finger: (tip_idx, pip_idx)
    fingers = {
        "index":  (8, 6),
        "middle": (12, 10),
        "ring":   (16, 14),
        "pinky":  (20, 18),
    }
    extended = {}
    for name, (tip, pip) in fingers.items():
        extended[name] = _dist(landmarks[tip], wrist) > _dist(landmarks[pip], wrist) * 1.10

    # Thumb: compare tip (4) vs IP (3) distance from wrist
    thumb_extended = _dist(landmarks[4], wrist) > _dist(landmarks[3], wrist) * 1.05

    return (
        extended["index"]
        and thumb_extended
        and not extended["middle"]
        and not extended["ring"]
        and not extended["pinky"]
    )


def draw_hand(frame, landmarks, palm_x, palm_y):
    h, w = frame.shape[:2]
    conns = [
        (0,1),(1,2),(2,3),(3,4),(0,5),(5,6),(6,7),(7,8),
        (0,9),(9,10),(10,11),(11,12),(0,13),(13,14),(14,15),(15,16),
        (0,17),(17,18),(18,19),(19,20),(5,9),(9,13),(13,17),
    ]
    for a, b in conns:
        p1 = (int(landmarks[a].x * w), int(landmarks[a].y * h))
        p2 = (int(landmarks[b].x * w), int(landmarks[b].y * h))
        cv2.line(frame, p1, p2, (0, 255, 0), 2)
    for lm in landmarks:
        cv2.circle(frame, (int(lm.x * w), int(lm.y * h)), 3, (0, 0, 255), -1)
    # Palm center
    cv2.circle(frame, (int(palm_x * w), int(palm_y * h)), 10, (255, 0, 255), -1)


def main():
    args = parse_args()
    download_model()

    # UDP
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    target = ("127.0.0.1", args.port)

    def send(msg):
        sock.sendto(msg.encode(), target)
        print(f"  >>> {msg}")

    # MediaPipe HandLandmarker in VIDEO mode for temporal tracking.
    # num_hands=2 so we can route each hand to a separate split-screen player.
    base_options = mp_python.BaseOptions(model_asset_path=MODEL_PATH)
    options = vision.HandLandmarkerOptions(
        base_options=base_options,
        running_mode=vision.RunningMode.VIDEO,
        num_hands=2,
        min_hand_detection_confidence=0.4,
        min_hand_presence_confidence=0.4,
        min_tracking_confidence=0.4,
    )
    landmarker = vision.HandLandmarker.create_from_options(options)

    # Camera
    cap = cv2.VideoCapture(args.camera)
    if not cap.isOpened():
        print("ERROR: Cannot open camera.")
        print("  macOS: System Settings > Privacy & Security > Camera > enable Terminal")
        print(f"  Tried camera index {args.camera}. Try --camera 1 or --camera 2")
        return

    cap_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    cap_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"Camera {args.camera} opened: {cap_w}x{cap_h}")
    print(f"Threshold: {args.threshold} | Cooldown: {args.cooldown}s")
    print(f"UDP → 127.0.0.1:{args.port}")
    print(f"Frames → {FRAME_PATH}")
    print("Press 'q' to quit.\n")

    # Send ping so Godot knows we connected
    send("ping")

    # Per-player gesture state. Player 1 = left half of frame, Player 2 = right.
    GUN_STREAK_NEEDED = 4
    state = {
        1: {"history": deque(maxlen=15), "last_t": 0.0, "last_g": "",
            "gun_streak": 0, "gun_armed": True},
        2: {"history": deque(maxlen=15), "last_t": 0.0, "last_g": "",
            "gun_streak": 0, "gun_armed": True},
    }
    frame_ts = 0  # MediaPipe needs increasing timestamps in ms

    # Frame saving
    last_frame_write = 0.0

    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                break

            frame = cv2.flip(frame, 1)
            now = time.time()

            # Convert and detect with VIDEO mode (needs timestamp in ms)
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            frame_ts += 33  # ~30fps timestamps
            result = landmarker.detect_for_video(mp_image, frame_ts)

            # Map each detected hand → a player based on its palm x position.
            # Left half of frame (x < 0.5) goes to Player 1, right half to P2.
            # If both hands land on the same side, the one closer to the
            # appropriate edge wins; the other is dropped to avoid duplicates.
            seen_players = set()
            per_player_lm = {}  # player_id -> (lm, px, py)
            if result.hand_landmarks:
                hands = []
                for lm in result.hand_landmarks:
                    px, py = get_palm_center(lm)
                    hands.append((px, py, lm))
                # Sort left-to-right; first → P1, second (if any) → P2.
                hands.sort(key=lambda h: h[0])
                if len(hands) >= 1:
                    px, py, lm = hands[0]
                    per_player_lm[1] = (lm, px, py)
                if len(hands) >= 2:
                    px, py, lm = hands[1]
                    per_player_lm[2] = (lm, px, py)

            # Process each player independently.
            last_detected = {}  # for HUD only
            for pid in (1, 2):
                s = state[pid]
                if pid not in per_player_lm:
                    s["history"].clear()
                    s["gun_streak"] = 0
                    s["gun_armed"] = True
                    continue
                lm, px, py = per_player_lm[pid]
                draw_hand(frame, lm, px, py)
                s["history"].append((now, px, py))
                detected = ""

                # Gun-sign detection (priority over swipes)
                if is_gun_sign(lm):
                    s["gun_streak"] += 1
                    if s["gun_streak"] >= GUN_STREAK_NEEDED and s["gun_armed"]:
                        if (now - s["last_t"]) >= args.cooldown:
                            detected = "shoot"
                            s["gun_armed"] = False
                else:
                    s["gun_streak"] = 0
                    s["gun_armed"] = True

                if not detected and len(s["history"]) >= 4:
                    target_age = 0.2
                    best_idx = 0
                    best_diff = abs(s["history"][0][0] - (now - target_age))
                    for i in range(1, len(s["history"])):
                        diff = abs(s["history"][i][0] - (now - target_age))
                        if diff < best_diff:
                            best_diff = diff
                            best_idx = i
                    old_t, old_x, old_y = s["history"][best_idx]
                    dt = now - old_t
                    if 0.08 < dt < 0.5:
                        dx = px - old_x
                        dy = py - old_y
                        in_cd = (now - s["last_t"]) < args.cooldown
                        if not in_cd and s["gun_streak"] == 0:
                            if abs(dx) > args.threshold and abs(dx) > abs(dy) * 1.3:
                                detected = "swipe_right" if dx > 0 else "swipe_left"
                            elif dy < -args.threshold and abs(dy) > abs(dx) * 1.3:
                                detected = "swipe_up"

                if detected:
                    send("p%d:%s" % (pid, detected))
                    s["last_t"] = now
                    s["last_g"] = detected
                    s["history"].clear()
                    last_detected[pid] = detected

            # === Draw UI ===
            fh, fw = frame.shape[:2]

            # Top bar
            cv2.rectangle(frame, (0, 0), (fw, 75), (0, 0, 0), -1)
            cv2.putText(frame, "3D Dino Hand Tracker", (10, 28),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)

            if result.hand_landmarks:
                cv2.putText(frame, "HANDS: %d" % len(result.hand_landmarks), (10, 55),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
            else:
                cv2.putText(frame, "Show one or two hands!", (10, 55),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2)

            # Vertical divider showing P1/P2 split
            cv2.line(frame, (fw // 2, 75), (fw // 2, fh), (180, 180, 180), 1)
            cv2.putText(frame, "P1", (fw // 4 - 15, fh - 12),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (180, 180, 180), 2)
            cv2.putText(frame, "P2", (3 * fw // 4 - 15, fh - 12),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (180, 180, 180), 2)

            # Gesture flash for whichever player just acted (newest wins)
            label_map = {
                "swipe_left": "<< LEFT",
                "swipe_right": "RIGHT >>",
                "swipe_up": "^ JUMP ^",
                "shoot": "* PEW! *",
            }
            for pid in (1, 2):
                s = state[pid]
                if s["last_g"] and (now - s["last_t"]) < 0.7:
                    label = "P%d %s" % (pid, label_map.get(s["last_g"], ""))
                    sz = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 1.2, 3)[0]
                    tx = (fw // 2 - sz[0]) // 2 if pid == 1 else fw // 2 + (fw // 2 - sz[0]) // 2
                    ty = fh // 2 + 20
                    cv2.rectangle(frame, (tx - 12, ty - sz[1] - 12), (tx + sz[0] + 12, ty + 12), (0, 0, 0), -1)
                    cv2.putText(frame, label, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (0, 255, 255), 3)

            # Save frame for Godot
            if now - last_frame_write >= 0.1:
                small = cv2.resize(frame, (320, 240))
                tmp = FRAME_PATH + ".tmp.jpg"
                cv2.imwrite(tmp, small, [cv2.IMWRITE_JPEG_QUALITY, 70])
                os.replace(tmp, FRAME_PATH)
                last_frame_write = now

            cv2.imshow("Hand Tracker", frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

    except KeyboardInterrupt:
        print("\nStopping...")
    finally:
        cap.release()
        cv2.destroyAllWindows()
        landmarker.close()
        sock.close()
        if os.path.exists(FRAME_PATH):
            os.remove(FRAME_PATH)
        print("Done.")


if __name__ == "__main__":
    main()
