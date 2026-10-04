# Assumes typical usage; self-test can be run with --self-test flag.
import cv2
import numpy as np
import argparse
import time
import sys
import os
import math
from typing import List, Tuple, Optional

def load_detector():
    path = os.path.join(cv2.data.haarcascades, "haarcascade_frontalface_default.xml")
    detector = cv2.CascadeClassifier(path)
    if detector.empty():
        raise RuntimeError("Failed to load Haar cascade for face detection")
    return detector



def detect_head(
    gray: np.ndarray,
    detector,
    _prev: any = None,
) -> Optional[Tuple[float, float, float]]:
    """
    Detect the largest face in ``gray`` using ``detector`` and return normalized
    coordinates.

    The x-coordinate is mirrored because the webcam image is not mirrored:
    moving to the user's right appears on the left side of the frame.

    Returns:
        (x_norm, y_norm, width_norm) where
        - x_norm  in [-1, 1]  (right = +1, left = -1 after mirroring)
        - y_norm  in [-1, 1]  (up = +1, down = -1)
        - width_norm = face width / frame width
        or ``None`` if no face is detected.
    """
    faces = detector.detectMultiScale(
        gray,
        scaleFactor=1.2,
        minNeighbors=5,
        minSize=(40, 40),
    )
    if len(faces) == 0:
        return None

    # Choose the face with the largest area
    x, y, w, h = max(faces, key=lambda r: r[2] * r[3])
    frame_h, frame_w = gray.shape
    cx = x + w / 2.0
    cy = y + h / 2.0

    # Mirrored horizontal normalisation
    x_norm = -(cx - frame_w / 2.0) / (frame_w / 2.0)   # right = +1 after mirroring
    y_norm = -(cy - frame_h / 2.0) / (frame_h / 2.0)   # up = +1
    width_norm = w / frame_w

    return (x_norm, y_norm, width_norm)


def build_scene(
    screen_w_cm: float,
    screen_h_cm: float,
    depth_cm: float = 40.0,
) -> List[Tuple[np.ndarray, np.ndarray]]:
    """
    Construct a list of 3-D line segments describing a rectangular room
    (front opening = screen) and five floating 2 cm targets.

    The room consists of:
    * Front plane at z = 0 (the screen).
    * Back wall at z = -depth.
    * Four side walls (left, right, floor, ceiling).

    A grid of 8x8 lines is drawn on the back wall.  Each side wall receives
    eight front-to-back lines evenly spaced across the wall, and eight rectangular
    "rings" at equally spaced depths between the front and back.

    Targets are placed at depths -5, -15, -25, -35, -30 cm, spread across the
    x-axis.  Each target is a 2 cm square and a line connects its centre directly
    to the back wall at the same (x, y) coordinate.

    Returns:
        List of (p1, p2) where each point is a ``np.ndarray`` of shape (3,).
    """
    half_w = screen_w_cm / 2.0
    half_h = screen_h_cm / 2.0

    # Corner points of the front plane (z = 0)
    fl = np.array([-half_w, -half_h, 0.0])
    fr = np.array([ half_w, -half_h, 0.0])
    bl = np.array([-half_w,  half_h, 0.0])
    br = np.array([ half_w,  half_h, 0.0])

    # Corresponding corners on the back wall (z = -depth)
    flb = fl - np.array([0.0, 0.0, depth_cm])
    frb = fr - np.array([0.0, 0.0, depth_cm])
    blb = bl - np.array([0.0, 0.0, depth_cm])
    brb = br - np.array([0.0, 0.0, depth_cm])

    segs: List[Tuple[np.ndarray, np.ndarray]] = []

    # ---------- Box edges (front -> back) ----------
    for front, back in [(fl, flb), (fr, frb), (bl, blb), (br, brb)]:
        segs.append((front, back))

    # ---------- Back wall grid (8 x 8) ----------
    divisions = 8
    xs = np.linspace(-half_w, half_w, divisions)
    ys = np.linspace(-half_h, half_h, divisions)

    # Vertical grid lines (constant x)
    for x in xs:
        segs.append(
            (
                np.array([x, -half_h, -depth_cm]),
                np.array([x,  half_h, -depth_cm]),
            )
        )
    # Horizontal grid lines (constant y)
    for y in ys:
        segs.append(
            (
                np.array([-half_w, y, -depth_cm]),
                np.array([ half_w, y, -depth_cm]),
            )
        )

    # ---------- Side walls ----------
    # Helper to add front-to-back lines on a wall
    def add_wall_lines(
        fixed_coord: float,
        varying_axis: str,
        wall_name: str,
    ) -> None:
        """
        ``fixed_coord`` is the constant coordinate (x for left/right, y for floor/ceiling).
        ``varying_axis`` is either 'y' (left/right walls) or 'x' (floor/ceiling).
        """
        positions = np.linspace(
            -half_h if varying_axis == "y" else -half_w,
            half_h if varying_axis == "y" else half_w,
            divisions,
        )
        for pos in positions:
            if varying_axis == "y":
                front = np.array([fixed_coord, pos, 0.0])
                back = np.array([fixed_coord, pos, -depth_cm])
            else:  # varying_axis == "x"
                front = np.array([pos, fixed_coord, 0.0])
                back = np.array([pos, fixed_coord, -depth_cm])
            segs.append((front, back))

    # Left wall (x = -half_w), varying y
    add_wall_lines(-half_w, "y", "left")
    # Right wall (x = +half_w), varying y
    add_wall_lines(half_w, "y", "right")
    # Floor (y = -half_h), varying x
    add_wall_lines(-half_h, "x", "floor")
    # Ceiling (y = +half_h), varying x
    add_wall_lines(half_h, "x", "ceiling")

    # Rings on side walls: rectangular perimeters at 8 depths
    depth_positions = np.linspace(0.0, -depth_cm, divisions)
    for z in depth_positions:
        # Left wall ring (vertical line segment already covered, but we close a loop)
        segs.append(
            (
                np.array([-half_w, -half_h, z]),
                np.array([-half_w,  half_h, z]),
            )
        )
        # Right wall ring
        segs.append(
            (
                np.array([half_w, -half_h, z]),
                np.array([half_w,  half_h, z]),
            )
        )
        # Floor ring
        segs.append(
            (
                np.array([-half_w, -half_h, z]),
                np.array([ half_w, -half_h, z]),
            )
        )
        # Ceiling ring
        segs.append(
            (
                np.array([-half_w, half_h, z]),
                np.array([ half_w, half_h, z]),
            )
        )

    # ---------- Floating targets ----------
    target_depths = [-5.0, -15.0, -25.0, -35.0, -30.0]  # cm
    target_size = 2.0  # cm (edge length of square)
    for i, z in enumerate(target_depths):
        # Spread targets across the width; centre at x = 0 when i == 2
        cx = (i - 2) * (screen_w_cm / 5.0)
        cy = 0.0

        half_sz = target_size / 2.0
        corners = [
            np.array([cx - half_sz, cy - half_sz, z]),
            np.array([cx + half_sz, cy - half_sz, z]),
            np.array([cx + half_sz, cy + half_sz, z]),
            np.array([cx - half_sz, cy + half_sz, z]),
        ]

        # Square outline
        for a, b in zip(corners, corners[1:] + [corners[0]]):
            segs.append((a, b))

        # Line from target centre straight to the back wall at same (x, y)
        segs.append(
            (
                np.array([cx, cy, z]),
                np.array([cx, cy, -depth_cm]),
            )
        )

    return segs


class Smoother:
    """Exponential smoother for tuples."""
    def __init__(self, alpha: float):
        self.alpha = alpha
        self.last = None

    def update(self, value):
        if value is None:
            return self.last
        if self.last is None:
            self.last = value
            return self.last
        smoothed = tuple(
            self.alpha * v + (1.0 - self.alpha) * l
            for v, l in zip(value, self.last)
        )
        self.last = smoothed
        return self.last

def head_to_eye(x_norm, y_norm, width_norm,
                screen_w_cm, cam_hfov_deg, face_w_cm=15.0):
    """Convert normalized head pose to eye position in cm."""
    if width_norm <= 0.0:
        width_norm = 0.001
    hfov_rad = math.radians(cam_hfov_deg)
    tan_half = math.tan(hfov_rad / 2.0)
    ez = face_w_cm / (2.0 * tan_half * width_norm)
    ez = max(25.0, min(200.0, ez))
    ex = x_norm * ez * tan_half
    ey = y_norm * ez * tan_half * 0.75
    return (ex, ey, ez)

def project(points_cm, eye, screen_w_cm, screen_h_cm, px_w, px_h):
    """Off-axis projection of 3D points onto screen (z=0). Returns int32 Nx2."""
    ex, ey, ez = eye
    pts = np.asarray(points_cm, dtype=np.float64)
    # t = ez / (ez - z)
    t = ez / (ez - pts[:, 2])
    sx = ex + (pts[:, 0] - ex) * t
    sy = ey + (pts[:, 1] - ey) * t
    # convert cm to pixel coordinates
    px = ((sx / screen_w_cm) + 0.5) * px_w
    py = (0.5 - (sy / screen_h_cm)) * px_h
    pix = np.stack([px, py], axis=1).astype(np.int32)
    return pix


def render(canvas, segments, eye,
           screen_w_cm, screen_h_cm):
    """Draw the scene onto the canvas."""
    canvas[:, :] = (30, 30, 30)  # near-black background
    h_px, w_px = canvas.shape[:2]
    # pre-project all unique points to speed up (optional)
    for p1, p2 in segments:
        pts = np.array([p1, p2])
        proj = project(pts, eye, screen_w_cm, screen_h_cm, w_px, h_px)
        # shading based on average depth (more negative = farther)
        depth = (p1[2] + p2[2]) / 2.0
        intensity = int(np.interp(depth, [-40.0, 0.0], [50, 200]))
        color = (intensity, intensity, intensity)
        cv2.line(canvas, tuple(proj[0]), tuple(proj[1]), color,
                 thickness=1, lineType=cv2.LINE_AA)



def _self_test():
    """Run self-tests; exit 0 on success, 1 on failure."""
    checks = 0
    try:
        # 1. Projection of a point on the screen plane should be identical for any eye.
        screen_w_cm = 60.0
        screen_h_cm = 34.0
        px_w, px_h = 640, 480
        point_on_screen = np.array([[0.0, 0.0, 0.0]])  # centre of screen
        eye_left = (-20.0, 0.0, 60.0)
        eye_right = (20.0, 0.0, 60.0)
        proj_left = project(point_on_screen, eye_left, screen_w_cm, screen_h_cm, px_w, px_h)
        proj_right = project(point_on_screen, eye_right, screen_w_cm, screen_h_cm, px_w, px_h)
        assert np.array_equal(proj_left, proj_right), "On-screen point projection differs"
        checks += 1

        # 2. A far point should move in the same direction as the eye moves (parallax).
        far_point = np.array([[0.0, 0.0, -40.0]])
        proj_left = project(far_point, eye_left, screen_w_cm, screen_h_cm, px_w, px_h)
        proj_right = project(far_point, eye_right, screen_w_cm, screen_h_cm, px_w, px_h)
        assert proj_right[0, 0] > proj_left[0, 0], "Parallax direction incorrect"
        checks += 1

        # 3. head_to_eye returns larger ez for smaller width_norm (face appears smaller -> farther).
        ez_small = head_to_eye(0.0, 0.0, 0.05, screen_w_cm, 60.0)[2]
        ez_large = head_to_eye(0.0, 0.0, 0.20, screen_w_cm, 60.0)[2]
        assert ez_small > ez_large, "Eye distance not inversely proportional to face size"
        checks += 1

        # 4. Smoother retains last value when given None.
        s = Smoother(0.5)
        first = (1.0, 2.0, 3.0)
        assert s.update(first) == first, "Smoother first update failed"
        assert s.update(None) == first, "Smoother did not keep value on None"
        checks += 1

        print(f"SELF-TEST PASS {checks} checks")
        sys.exit(0)
    except AssertionError as e:
        print(f"SELF-TEST FAILURE: {e}")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Head-tracked parallax demo")
    parser.add_argument("--camera", type=int, default=0, help="Camera index")
    parser.add_argument("--screen-width-cm", type=float, default=60.0, help="Screen width in cm")
    parser.add_argument("--screen-height-cm", type=float, default=34.0, help="Screen height in cm")
    parser.add_argument("--hfov", type=float, default=60.0, help="Camera horizontal FOV in degrees")
    parser.add_argument("--smooth", type=float, default=0.35, help="Exponential smoothing factor")
    parser.add_argument("--windowed", action="store_true", help="Run in windowed mode (1280x720)")
    parser.add_argument("--show-camera", action="store_true", help="Show camera preview inset")
    parser.add_argument("--self-test", action="store_true", help="Run internal self-tests and exit")
    parser.add_argument("--max-seconds", type=float, default=0.0, help="Quit after N seconds (0 = run until Q)")
    args = parser.parse_args()

    if args.self_test:
        _self_test()

    # Load face detector
    detector = load_detector()

    # Open camera
    cap = cv2.VideoCapture(args.camera, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    if not cap.isOpened():
        print("ERROR: Unable to open camera.", file=sys.stderr)
        sys.exit(2)

    # Prepare window
    win_name = "Head Parallax"
    cv2.namedWindow(win_name, cv2.WINDOW_NORMAL)
    if args.windowed:
        cv2.resizeWindow(win_name, 1280, 720)
    else:
        cv2.setWindowProperty(win_name, cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)

    # Build static scene
    segments = build_scene(args.screen_width_cm, args.screen_height_cm)

    smoother = Smoother(args.smooth)
    default_eye = (0.0, 0.0, 60.0)

    prev_time = time.time()
    start_time = prev_time
    fps = 0.0
    frames = 0
    faces_seen = 0

    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                break

            gray_full = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            # Detect on half-size image for speed
            gray = cv2.resize(gray_full, (gray_full.shape[1] // 2, gray_full.shape[0] // 2))
            gray = cv2.equalizeHist(gray)  # dark rooms: C270 frames measured at mean 10.9/255

            head = detect_head(gray, detector, None)
            frames += 1
            faces_seen += head is not None
            smoothed = smoother.update(head)

            if smoothed is not None:
                eye = head_to_eye(*smoothed,
                                  args.screen_width_cm,
                                  args.hfov)
            else:
                eye = default_eye

            # Prepare canvas matching display size
            if args.windowed:
                canvas_h, canvas_w = 720, 1280
            else:
                # Use screen size of the primary monitor (fallback to 1280x720)
                canvas_w = int(cv2.getWindowImageRect(win_name)[2]) or 1280
                canvas_h = int(cv2.getWindowImageRect(win_name)[3]) or 720
            canvas = np.zeros((canvas_h, canvas_w, 3), dtype=np.uint8)

            # Render 3-D scene
            render(canvas, segments, eye,
                   args.screen_width_cm, args.screen_height_cm)

            # Optional camera preview inset
            if args.show_camera:
                preview = cv2.resize(frame, (160, 120))
                y_start = canvas_h - 120
                x_start = canvas_w - 160
                canvas[y_start:y_start + 120, x_start:x_start + 160] = preview

            # Overlay status text
            cv2.putText(canvas, "CAMERA ON - local only - Q to quit",
                        (10, 30), cv2.FONT_HERSHEY_SIMPLEX,
                        0.8, (255, 255, 255), 2, cv2.LINE_AA)

            # FPS calculation
            cur_time = time.time()
            fps = 0.9 * fps + 0.1 * (1.0 / (cur_time - prev_time))
            prev_time = cur_time
            cv2.putText(canvas, f"FPS: {fps:.1f}",
                        (10, canvas_h - 10), cv2.FONT_HERSHEY_SIMPLEX,
                        0.7, (255, 255, 0), 2, cv2.LINE_AA)

            cv2.imshow(win_name, canvas)

            # Handle exit keys and window close
            key = cv2.waitKey(1) & 0xFF
            if key in (ord('q'), 27):
                break
            if cv2.getWindowProperty(win_name, cv2.WND_PROP_VISIBLE) < 1:
                break
            if args.max_seconds and cur_time - start_time >= args.max_seconds:
                break
    finally:
        cap.release()
        cv2.destroyAllWindows()
        print(f"frames={frames} faces={faces_seen} fps={fps:.1f} camera_released=True")


if __name__ == "__main__":
    main()
