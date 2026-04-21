import serial
import socket
import time

# --- CONFIG ---
SERIAL_PORT = '/dev/ttyACM0'
UDP_PORT    = 6789

# Joystick thresholds
X_LEFT  = 200
X_RIGHT = 800
Y_UP    = 800

# Sudden change in pitch degrees between frames = shoot gesture
# Tune this value — lower = more sensitive, higher = requires sharper jerk
JERK_DELTA = 30

COOLDOWN = 0.4  # seconds between gestures

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ser  = serial.Serial(SERIAL_PORT, 115200, timeout=1)

last_gesture_time = 0
prev_btn = 1  # INPUT_PULLUP: 1 = not pressed
prev_pitch = 0

def send(gesture):
    global last_gesture_time
    if time.time() - last_gesture_time < COOLDOWN:
        return
    sock.sendto(gesture.encode(), ('127.0.0.1', UDP_PORT))
    print(f"P1 → {gesture}")
    last_gesture_time = time.time()

print(f"P1 bridge running on {SERIAL_PORT} → UDP {UDP_PORT}")

while True:
    try:
        line = ser.readline().decode().strip()
        if not line or line.count(',') != 3:
            continue

        parts = line.split(',')
        x     = int(parts[0])
        y     = int(parts[1])
        btn   = int(parts[2])
        pitch = int(parts[3])

        delta = abs(pitch - prev_pitch)
        prev_pitch = pitch

        if   y < X_LEFT:   send("swipe_left")
        elif y > X_RIGHT:  send("swipe_right")
        elif x > Y_UP:     send("swipe_up")

        # Sudden upward jerk = shoot
        if delta > JERK_DELTA:
            send("shoot")

        # Button also shoots
        if btn == 0 and prev_btn == 1:
            send("shoot")
        prev_btn = btn

    except (ValueError, UnicodeDecodeError):
        continue
    except KeyboardInterrupt:
        print("P1 bridge stopped.")
        break
