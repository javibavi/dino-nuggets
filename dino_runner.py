#!/usr/bin/env python3
"""3D Dino Endless Runner — Hand Gesture + Keyboard Control.

Single-file game using Pygame (rendering) + MediaPipe (hand tracking).
No separate processes, no UDP, no inter-process communication.

Usage:
    python3 dino_runner.py --camera 1          # With hand tracking
    python3 dino_runner.py --no-camera         # Keyboard only
"""

import argparse
import math
import os
import random
import time
from collections import deque

import cv2
import numpy as np
import pygame

import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision

# ─── Constants ───────────────────────────────────────────────────────────────

SCREEN_WIDTH = 1280
SCREEN_HEIGHT = 720
FPS = 60

# Game world
LANE_WIDTH = 2.5
LANES = [-1, 0, 1]

# Player
PLAYER_SIZE = 1.0
JUMP_VELOCITY = 12.0
GRAVITY = 30.0
LANE_SWITCH_SPEED = 12.0

# Obstacles
SPAWN_DISTANCE = 80.0
DESPAWN_Z = -2.0
TALL_HEIGHT = 2.0
LOW_HEIGHT = 0.5
TALL_CHANCE = 0.6

# Speed / difficulty
INITIAL_SPEED = 15.0
MAX_SPEED = 40.0
SPEED_INCREASE = 0.5
MIN_SPAWN_INTERVAL = 0.6
MAX_SPAWN_INTERVAL = 1.5

# Perspective
HORIZON_Y = SCREEN_HEIGHT * 0.35
ROAD_BOTTOM_Y = SCREEN_HEIGHT - 50
ROAD_TOP_W = 60
ROAD_BOTTOM_W = SCREEN_WIDTH * 0.65
VIEW_DIST = 80.0

# Camera overlay
CAM_W, CAM_H = 240, 180

# Colors
SKY = (135, 206, 235)
GROUND = (64, 64, 71)
GROUND_STRIPE = (74, 74, 81)
PLAYER_COL = (51, 217, 77)
PLAYER_TOP = (81, 237, 107)
PLAYER_EDGE = (31, 177, 57)
OBS_TALL_COL = (230, 38, 38)
OBS_TALL_TOP = (255, 78, 78)
OBS_TALL_EDGE = (180, 20, 20)
OBS_LOW_COL = (230, 150, 38)
OBS_LOW_TOP = (255, 180, 68)
OBS_LOW_EDGE = (190, 120, 20)
LANE_COL = (90, 90, 100)
WHITE = (255, 255, 255)
BLACK = (0, 0, 0)
YELLOW = (255, 255, 0)
GRAY = (180, 180, 180)


# ─── Perspective Renderer ────────────────────────────────────────────────────

class Renderer:
    """Vanishing-point pseudo-3D projection."""

    def __init__(self):
        self.cx = SCREEN_WIDTH / 2
        self.vy = HORIZON_Y
        self.scale_k = 0.08  # perspective strength

    def project(self, wx, wy, wz):
        """World (x, y, z) → screen (sx, sy, scale). z>0 = ahead."""
        wz = max(wz, 0.05)
        s = 1.0 / (1.0 + wz * self.scale_k)
        px_per_unit = ROAD_BOTTOM_W / (len(LANES) * LANE_WIDTH)
        sx = self.cx + wx * s * px_per_unit
        ground_sy = ROAD_BOTTOM_Y - (ROAD_BOTTOM_Y - self.vy) * (1.0 - s)
        sy = ground_sy - wy * s * px_per_unit
        return sx, sy, s

    def draw_road(self, screen, scroll):
        """Draw road surface, lane lines, scrolling stripes."""
        cx = self.cx
        vy = self.vy
        ht = ROAD_TOP_W / 2
        hb = ROAD_BOTTOM_W / 2

        # Road surface
        pygame.draw.polygon(screen, GROUND, [
            (cx - ht, vy), (cx + ht, vy),
            (cx + hb, ROAD_BOTTOM_Y), (cx - hb, ROAD_BOTTOM_Y),
        ])

        # Scrolling horizontal stripes
        for i in range(30):
            z = (i / 30) * VIEW_DIST
            z = (z + scroll) % VIEW_DIST
            _, gy, s = self.project(0, 0, z)
            if gy < vy or gy > ROAD_BOTTOM_Y:
                continue
            hw = hb * s
            pygame.draw.line(screen, GROUND_STRIPE,
                             (cx - hw, int(gy)), (cx + hw, int(gy)), 1)

        # Lane dividers
        ppu = ROAD_BOTTOM_W / (len(LANES) * LANE_WIDTH)
        for edge in [-0.5, 0.5]:
            bx = cx + edge * LANE_WIDTH * ppu
            pygame.draw.line(screen, LANE_COL, (cx, int(vy)), (int(bx), int(ROAD_BOTTOM_Y)), 2)

        # Road edges
        pygame.draw.line(screen, LANE_COL, (cx - ht, int(vy)), (cx - hb, int(ROAD_BOTTOM_Y)), 3)
        pygame.draw.line(screen, LANE_COL, (cx + ht, int(vy)), (cx + hb, int(ROAD_BOTTOM_Y)), 3)

    def draw_box(self, screen, wx, wy, wz, w, h, face_col, top_col, edge_col):
        """Draw a colored box at world position."""
        sx, sy_top, s = self.project(wx, wy + h, wz)
        _, sy_bot, _ = self.project(wx, wy, wz)

        ppu = ROAD_BOTTOM_W / (len(LANES) * LANE_WIDTH)
        pw = w * s * ppu
        ph = sy_bot - sy_top

        if pw < 1 or ph < 1 or sy_bot < HORIZON_Y:
            return

        # Front face
        rect = pygame.Rect(sx - pw / 2, sy_top, pw, ph)
        pygame.draw.rect(screen, face_col, rect)
        pygame.draw.rect(screen, edge_col, rect, max(1, int(s * 3)))

        # Top face
        tw = pw * 0.85
        th = pw * 0.3
        top_rect = pygame.Rect(sx - tw / 2, sy_top - th, tw, th)
        pygame.draw.rect(screen, top_col, top_rect)
        pygame.draw.rect(screen, edge_col, top_rect, max(1, int(s * 2)))


# ─── Player ──────────────────────────────────────────────────────────────────

class Player:
    def __init__(self):
        self.reset()

    def reset(self):
        self.lane = 0
        self.x = 0.0
        self.target_x = 0.0
        self.y = 0.0
        self.vy = 0.0
        self.dead = False

    def move_lane(self, d):
        if self.dead:
            return
        new = max(-1, min(1, self.lane + d))
        if new != self.lane:
            self.lane = new
            self.target_x = self.lane * LANE_WIDTH

    def jump(self):
        if self.dead or self.y > 0.05:
            return
        self.vy = JUMP_VELOCITY

    def update(self, dt):
        if self.dead:
            return
        # Lane lerp
        diff = self.target_x - self.x
        step = LANE_SWITCH_SPEED * dt
        self.x = self.target_x if abs(diff) <= step else self.x + (step if diff > 0 else -step)
        # Gravity
        self.vy -= GRAVITY * dt
        self.y += self.vy * dt
        if self.y <= 0:
            self.y = 0
            if self.vy < 0:
                self.vy = 0


# ─── Obstacle ────────────────────────────────────────────────────────────────

class Obstacle:
    def __init__(self, lane, is_tall):
        self.lane = lane
        self.x = lane * LANE_WIDTH
        self.z = SPAWN_DISTANCE
        self.is_tall = is_tall
        self.h = TALL_HEIGHT if is_tall else LOW_HEIGHT

    def update(self, dt, speed):
        self.z -= speed * dt

    def collides(self, player):
        if abs(player.x - self.x) > 0.9:
            return False
        if abs(self.z) > 1.0:
            return False
        if self.is_tall:
            return True
        return player.y < self.h - 0.1


# ─── Hand Tracker ────────────────────────────────────────────────────────────

class HandTracker:
    def __init__(self, cam_idx, model_path, threshold=0.07, cooldown=0.5):
        self.threshold = threshold
        self.cooldown = cooldown
        self.active = False
        self.hand_detected = False
        self.surface = None

        self.cap = cv2.VideoCapture(cam_idx)
        if not self.cap.isOpened():
            print(f"WARNING: Cannot open camera {cam_idx}. Hand tracking disabled.")
            return

        if not os.path.exists(model_path):
            print(f"WARNING: Model not found at {model_path}. Hand tracking disabled.")
            self.cap.release()
            return

        base = mp_python.BaseOptions(model_asset_path=model_path)
        opts = vision.HandLandmarkerOptions(
            base_options=base,
            running_mode=vision.RunningMode.VIDEO,
            num_hands=1,
            min_hand_detection_confidence=0.4,
            min_hand_presence_confidence=0.4,
            min_tracking_confidence=0.4,
        )
        self.landmarker = vision.HandLandmarker.create_from_options(opts)
        self.active = True
        self.history = deque(maxlen=15)
        self.last_gesture_time = 0.0
        self.frame_ts = 0
        print(f"Hand tracker ready (camera {cam_idx}, threshold {threshold})")

    def update(self):
        if not self.active:
            return None

        ret, frame = self.cap.read()
        if not ret:
            return None

        frame = cv2.flip(frame, 1)
        now = time.time()

        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        self.frame_ts += 33
        result = self.landmarker.detect_for_video(mp_img, self.frame_ts)

        gesture = None
        self.hand_detected = bool(result.hand_landmarks)

        if result.hand_landmarks:
            lm = result.hand_landmarks[0]
            px, py = self._palm(lm)
            self._draw_hand(frame, lm, px, py)
            self.history.append((now, px, py))

            if len(self.history) >= 4:
                # Find entry ~0.2s ago
                target = now - 0.2
                best_i = min(range(len(self.history)),
                             key=lambda i: abs(self.history[i][0] - target))
                ot, ox, oy = self.history[best_i]
                dt = now - ot

                if 0.08 < dt < 0.5:
                    dx = px - ox
                    dy = py - oy
                    if (now - self.last_gesture_time) >= self.cooldown:
                        if abs(dx) > self.threshold and abs(dx) > abs(dy) * 1.3:
                            gesture = "swipe_right" if dx > 0 else "swipe_left"
                        elif dy < -self.threshold and abs(dy) > abs(dx) * 1.3:
                            gesture = "swipe_up"

            if gesture:
                self.last_gesture_time = now
                self.history.clear()
        else:
            self.history.clear()

        # Convert frame to pygame surface for preview
        small = cv2.resize(frame, (CAM_W, CAM_H))
        small_rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
        self.surface = pygame.surfarray.make_surface(np.transpose(small_rgb, (1, 0, 2)))

        return gesture

    def _palm(self, lm):
        pts = [lm[i] for i in (0, 5, 9, 13, 17)]
        return sum(p.x for p in pts) / 5, sum(p.y for p in pts) / 5

    def _draw_hand(self, frame, lm, px, py):
        h, w = frame.shape[:2]
        conns = [
            (0,1),(1,2),(2,3),(3,4),(0,5),(5,6),(6,7),(7,8),
            (0,9),(9,10),(10,11),(11,12),(0,13),(13,14),(14,15),(15,16),
            (0,17),(17,18),(18,19),(19,20),(5,9),(9,13),(13,17),
        ]
        for a, b in conns:
            p1 = (int(lm[a].x * w), int(lm[a].y * h))
            p2 = (int(lm[b].x * w), int(lm[b].y * h))
            cv2.line(frame, p1, p2, (0, 255, 0), 2)
        for pt in lm:
            cv2.circle(frame, (int(pt.x * w), int(pt.y * h)), 3, (0, 0, 255), -1)
        cv2.circle(frame, (int(px * w), int(py * h)), 10, (255, 0, 255), -1)

    def close(self):
        if self.active:
            self.cap.release()
            self.landmarker.close()


# ─── Game ────────────────────────────────────────────────────────────────────

class Game:
    def __init__(self):
        self.renderer = Renderer()
        self.player = Player()
        self.obstacles = []
        self.score = 0.0
        self.speed = INITIAL_SPEED
        self.game_over = False
        self.spawn_timer = MAX_SPAWN_INTERVAL
        self.scroll = 0.0
        self.gesture_text = ""
        self.gesture_timer = 0.0

        self.font_big = pygame.font.SysFont("Helvetica", 48, bold=True)
        self.font_med = pygame.font.SysFont("Helvetica", 32)
        self.font_sm = pygame.font.SysFont("Helvetica", 22)

    def handle(self, gesture, keys):
        if self.game_over:
            if gesture == "swipe_up" or keys.get("restart") or keys.get("jump"):
                self.reset()
            return

        if gesture == "swipe_left":
            self.player.move_lane(-1)
            self._show_gesture("<< LEFT")
        elif gesture == "swipe_right":
            self.player.move_lane(1)
            self._show_gesture("RIGHT >>")
        elif gesture == "swipe_up":
            self.player.jump()
            self._show_gesture("^ JUMP ^")

        if keys.get("left"):
            self.player.move_lane(-1)
        if keys.get("right"):
            self.player.move_lane(1)
        if keys.get("jump"):
            self.player.jump()

    def _show_gesture(self, text):
        self.gesture_text = text
        self.gesture_timer = 1.0

    def update(self, dt):
        if self.game_over:
            return

        self.score += self.speed * dt
        self.speed = min(self.speed + SPEED_INCREASE * dt, MAX_SPEED)

        t = (self.speed - INITIAL_SPEED) / (MAX_SPEED - INITIAL_SPEED)
        interval = MAX_SPAWN_INTERVAL + t * (MIN_SPAWN_INTERVAL - MAX_SPAWN_INTERVAL)

        self.spawn_timer -= dt
        if self.spawn_timer <= 0:
            lane = random.choice(LANES)
            tall = random.random() < TALL_CHANCE
            self.obstacles.append(Obstacle(lane, tall))
            self.spawn_timer = interval

        self.player.update(dt)

        for o in self.obstacles:
            o.update(dt, self.speed)
            if o.collides(self.player):
                self.player.dead = True
                self.game_over = True

        self.obstacles = [o for o in self.obstacles if o.z > DESPAWN_Z]
        self.scroll += self.speed * dt

        if self.gesture_timer > 0:
            self.gesture_timer -= dt

    def draw(self, screen, cam_surf=None, hand_ok=False):
        screen.fill(SKY)
        self.renderer.draw_road(screen, self.scroll)

        # Collect drawables, sort back→front
        items = []
        for o in self.obstacles:
            if o.z > 0:
                if o.is_tall:
                    items.append((o.z, o.x, 0, o.h, OBS_TALL_COL, OBS_TALL_TOP, OBS_TALL_EDGE))
                else:
                    items.append((o.z, o.x, 0, o.h, OBS_LOW_COL, OBS_LOW_TOP, OBS_LOW_EDGE))
        items.append((0.01, self.player.x, self.player.y, PLAYER_SIZE,
                       PLAYER_COL, PLAYER_TOP, PLAYER_EDGE))
        items.sort(key=lambda i: i[0], reverse=True)

        for z, x, y, h, fc, tc, ec in items:
            self.renderer.draw_box(screen, x, y, z, 1.0, h, fc, tc, ec)

        # UI: Score
        self._text(screen, f"Score: {int(self.score)}", self.font_med, WHITE, 20, 15)
        self._text(screen, f"Speed: {self.speed:.0f}", self.font_sm, GRAY, 20, 52)

        # UI: Gesture
        if self.gesture_timer > 0 and self.gesture_text:
            t = self.font_med.render(self.gesture_text, True, YELLOW)
            screen.blit(t, (SCREEN_WIDTH - t.get_width() - 20, 15))

        # UI: Hand status
        if cam_surf is not None:
            status = "Hand: OK" if hand_ok else "Show your hand"
            color = (0, 255, 0) if hand_ok else (255, 100, 100)
            self._text(screen, status, self.font_sm, color,
                       SCREEN_WIDTH - CAM_W - 15, SCREEN_HEIGHT - CAM_H - 40)

        # Camera preview
        if cam_surf:
            cx = SCREEN_WIDTH - CAM_W - 15
            cy = SCREEN_HEIGHT - CAM_H - 15
            pygame.draw.rect(screen, WHITE, (cx - 2, cy - 2, CAM_W + 4, CAM_H + 4), 2)
            screen.blit(cam_surf, (cx, cy))

        # Game over
        if self.game_over:
            overlay = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
            overlay.fill((0, 0, 0, 140))
            screen.blit(overlay, (0, 0))
            self._center(screen, "GAME OVER", self.font_big, WHITE, -50)
            self._center(screen, f"Score: {int(self.score)}", self.font_med, WHITE, 10)
            self._center(screen, "Press R or Swipe Up to restart", self.font_sm, GRAY, 55)

    def _text(self, screen, txt, font, col, x, y):
        screen.blit(font.render(txt, True, col), (x, y))

    def _center(self, screen, txt, font, col, y_off):
        t = font.render(txt, True, col)
        screen.blit(t, (SCREEN_WIDTH // 2 - t.get_width() // 2,
                         SCREEN_HEIGHT // 2 + y_off))

    def reset(self):
        self.player.reset()
        self.obstacles.clear()
        self.score = 0.0
        self.speed = INITIAL_SPEED
        self.game_over = False
        self.spawn_timer = MAX_SPAWN_INTERVAL
        self.scroll = 0.0


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="3D Dino Runner")
    parser.add_argument("--camera", type=int, default=0, help="Webcam index")
    parser.add_argument("--threshold", type=float, default=0.07, help="Swipe threshold")
    parser.add_argument("--cooldown", type=float, default=0.5, help="Gesture cooldown (s)")
    parser.add_argument("--no-camera", action="store_true", help="Keyboard only")
    args = parser.parse_args()

    pygame.init()
    screen = pygame.display.set_mode((SCREEN_WIDTH, SCREEN_HEIGHT))
    pygame.display.set_caption("3D Dino Runner")
    clock = pygame.time.Clock()

    game = Game()
    tracker = None

    if not args.no_camera:
        model = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "hand_tracker", "hand_landmarker.task")
        tracker = HandTracker(args.camera, model, args.threshold, args.cooldown)
        if not tracker.active:
            print("Falling back to keyboard only.")
            tracker = None

    print("\n=== 3D Dino Runner ===")
    print("Controls: Arrow keys / WASD + Space to jump")
    if tracker:
        print("Hand gestures: Swipe left/right/up")
    print("Press ESC to quit\n")

    running = True
    while running:
        dt = min(clock.tick(FPS) / 1000.0, 0.05)

        keys = {}
        for ev in pygame.event.get():
            if ev.type == pygame.QUIT:
                running = False
            elif ev.type == pygame.KEYDOWN:
                if ev.key == pygame.K_ESCAPE:
                    running = False
                elif ev.key in (pygame.K_LEFT, pygame.K_a):
                    keys["left"] = True
                elif ev.key in (pygame.K_RIGHT, pygame.K_d):
                    keys["right"] = True
                elif ev.key in (pygame.K_SPACE, pygame.K_UP):
                    keys["jump"] = True
                elif ev.key == pygame.K_r:
                    keys["restart"] = True

        gesture = tracker.update() if tracker else None
        game.handle(gesture, keys)
        game.update(dt)

        cam = tracker.surface if tracker else None
        hand = tracker.hand_detected if tracker else False
        game.draw(screen, cam, hand)

        pygame.display.flip()

    if tracker:
        tracker.close()
    pygame.quit()


if __name__ == "__main__":
    main()
