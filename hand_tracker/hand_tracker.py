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

    # MediaPipe HandLandmarker in VIDEO mode for temporal tracking
    base_options = mp_python.BaseOptions(model_asset_path=MODEL_PATH)
    options = vision.HandLandmarkerOptions(
        base_options=base_options,
        running_mode=vision.RunningMode.VIDEO,
        num_hands=1,
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

    # Gesture state
    history = deque(maxlen=15)
    last_gesture_time = 0.0
    last_gesture = ""
    frame_ts = 0  # MediaPipe needs increasing timestamps in ms

    # Gun-sign tracking — require N consecutive frames before firing,
    # then require a non-gun frame before re-arming.
    gun_streak = 0
    gun_armed = True
    GUN_STREAK_NEEDED = 4

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

            detected = ""

            if result.hand_landmarks:
                lm = result.hand_landmarks[0]
                px, py = get_palm_center(lm)
                draw_hand(frame, lm, px, py)

                history.append((now, px, py))

                # Gun-sign detection (priority over swipes)
                if is_gun_sign(lm):
                    gun_streak += 1
                    if gun_streak >= GUN_STREAK_NEEDED and gun_armed:
                        if (now - last_gesture_time) >= args.cooldown:
                            detected = "shoot"
                            gun_armed = False
                else:
                    gun_streak = 0
                    gun_armed = True

                # Need enough history points
                if not detected and len(history) >= 4:
                    # Compare current to position ~0.15-0.3s ago
                    target_age = 0.2
                    best_idx = 0
                    best_diff = abs(history[0][0] - (now - target_age))
                    for i in range(1, len(history)):
                        diff = abs(history[i][0] - (now - target_age))
                        if diff < best_diff:
                            best_diff = diff
                            best_idx = i

                    old_t, old_x, old_y = history[best_idx]
                    dt = now - old_t

                    if 0.08 < dt < 0.5:
                        dx = px - old_x
                        dy = py - old_y
                        in_cd = (now - last_gesture_time) < args.cooldown

                        if not in_cd and gun_streak == 0:
                            # Horizontal swipe
                            if abs(dx) > args.threshold and abs(dx) > abs(dy) * 1.3:
                                detected = "swipe_right" if dx > 0 else "swipe_left"
                            # Upward swipe (y decreases going up)
                            elif dy < -args.threshold and abs(dy) > abs(dx) * 1.3:
                                detected = "swipe_up"

                if detected:
                    send(detected)
                    last_gesture_time = now
                    last_gesture = detected
                    history.clear()
            else:
                history.clear()

            # === Draw UI ===
            fh, fw = frame.shape[:2]

            # Top bar
            cv2.rectangle(frame, (0, 0), (fw, 75), (0, 0, 0), -1)
            cv2.putText(frame, "3D Dino Hand Tracker", (10, 28),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)

            if result.hand_landmarks:
                cv2.putText(frame, "HAND OK", (10, 55),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
                # Debug: show movement values
                if len(history) >= 2:
                    dx = history[-1][1] - history[0][1]
                    dy = history[-1][2] - history[0][2]
                    thr = args.threshold
                    bar_w = 200
                    bar_y = 65
                    # dx bar
                    bar_dx = int(max(-1, min(1, dx / thr)) * bar_w / 2)
                    cv2.rectangle(frame, (300, bar_y - 5), (300 + bar_w, bar_y + 5), (50, 50, 50), -1)
                    center_x = 300 + bar_w // 2
                    color = (0, 255, 255) if abs(dx) > thr else (100, 100, 100)
                    cv2.rectangle(frame, (center_x, bar_y - 5), (center_x + bar_dx, bar_y + 5), color, -1)
                    cv2.putText(frame, "L/R", (300 - 30, bar_y + 5), cv2.FONT_HERSHEY_SIMPLEX, 0.3, (200, 200, 200), 1)
            else:
                cv2.putText(frame, "Show your hand to the camera!", (10, 55),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2)

            # Gesture flash
            if last_gesture and (now - last_gesture_time) < 0.7:
                label = {
                    "swipe_left": "<< LEFT",
                    "swipe_right": "RIGHT >>",
                    "swipe_up": "^ JUMP ^",
                    "shoot": "* PEW! *",
                }.get(last_gesture, "")
                sz = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 1.8, 3)[0]
                tx = (fw - sz[0]) // 2
                ty = fh // 2 + 20
                cv2.rectangle(frame, (tx - 15, ty - sz[1] - 15), (tx + sz[0] + 15, ty + 15), (0, 0, 0), -1)
                cv2.putText(frame, label, (tx, ty), cv2.FONT_HERSHEY_SIMPLEX, 1.8, (0, 255, 255), 3)

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
