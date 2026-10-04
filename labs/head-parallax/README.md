# head-parallax (lab prototype)

Webcam head tracking drives an off-axis projection, so the monitor looks like a
window into a 3D box. This is the effect in the reel Tre sent (TouchDesigner,
"off axis projection"). It is a LAB item: it is not in the windows-tune menu.

## Run

    python -m venv .venv
    .venv\Scripts\python -m pip install --no-deps opencv-python==4.10.0.84 numpy==2.1.3
    .venv\Scripts\python head_parallax.py              # fullscreen, Q or Esc quits
    .venv\Scripts\python head_parallax.py --windowed --show-camera
    .venv\Scripts\python head_parallax.py --self-test  # no camera, no window

Set `--screen-width-cm` / `--screen-height-cm` to the real monitor size for
correct depth. Pinned wheel hashes (checked against PyPI, 2026-10-04):
opencv-python 4.10.0.84 win_amd64 `32dbbd94...e48fe`, numpy 2.1.3 cp313
`74764163...df9ed`.

## Privacy line

- Frames are read, turned into one face box, and dropped. Nothing is saved.
- No network code: imports are cv2, numpy and the standard library only. The
  face model is the Haar cascade that ships inside the OpenCV wheel.
- The webcam light is on while it runs. The screen says "CAMERA ON". Q, Esc or
  closing the window stops it, and the camera is released in a `finally` block.

## Measured cost (7700X, 2026-10-04)

Face detect 15.2 ms per frame at 320x240, render 21.6 ms at 2560x1440, one CPU
thread, no GPU. That is about 27 fps on one of 16 threads.

## Not covered yet

- Not run against a live camera: the Logi C270 reads "Unknown" (unplugged), so
  only the exit-2 "cannot open camera" path is proven.
- It is a fullscreen window, not the wallpaper behind the icons. Putting it
  behind the desktop needs Lively or Wallpaper Engine, which needs a security
  review first.
- Haar tracking is jittery in low light. MediaPipe would be smoother but needs a
  model download.
