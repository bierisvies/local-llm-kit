"""Drive a Windows desktop app with real keyboard/mouse input and take screenshots.

Input is injected with SendInput, so it reaches games that read Raw Input,
DirectInput or GLFW/Raylib key state (unlike SendKeys).

Usage:
  python drive-app.py --exe path\\to\\App.exe --steps "wait 2; key down; key space; wait 4; shot a.png; move 300 0 0.3; click; wait 0.5; shot b.png" --close
  python drive-app.py --process AimTrainer.App --steps "shot now.png"

Steps (separated by ';'):
  wait S                 sleep S seconds
  key NAME [N]           press a key N times (space, enter, esc, tab, up, down, left, right, a-z, 0-9, f1-f12)
  hold NAME S            hold a key down for S seconds
  move DX DY [S]         relative mouse move in raw counts, spread over S seconds (default instant)
  click [left|right]     mouse click
  mousedown / mouseup    press or release the left button
  shot FILE.png          screenshot of the app window
Output: one line per step, then the process state. Exit code 1 if the app crashed.
"""
import argparse, ctypes, subprocess, sys, time
from ctypes import wintypes
from PIL import ImageGrab

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.SetProcessDPIAware()

INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE = 0x1, 0x2, 0x8
MOUSEEVENTF_MOVE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x1, 0x2, 0x4
MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP = 0x8, 0x10
ULONG_PTR = ctypes.c_size_t

class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]

class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]

class _U(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]

class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _U)]

# name -> (scan code, extended)
SCAN = {"esc": (0x01, False), "escape": (0x01, False), "tab": (0x0F, False), "enter": (0x1C, False),
        "space": (0x39, False), "backspace": (0x0E, False), "lshift": (0x2A, False), "lctrl": (0x1D, False),
        "up": (0x48, True), "down": (0x50, True), "left": (0x4B, True), "right": (0x4D, True)}
for i, c in enumerate("1234567890"): SCAN[c] = (0x02 + i, False)
for row, start in (("qwertyuiop", 0x10), ("asdfghjkl", 0x1E), ("zxcvbnm", 0x2C)):
    for i, c in enumerate(row): SCAN[c] = (start + i, False)
for i in range(10): SCAN[f"f{i + 1}"] = (0x3B + i, False)
SCAN["f11"], SCAN["f12"] = (0x57, False), (0x58, False)

def send(*inputs):
    arr = (INPUT * len(inputs))(*inputs)
    if user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT)) != len(inputs):
        raise OSError(ctypes.get_last_error(), "SendInput failed (is the window blocked by UAC/admin?)")

def key_event(name, up):
    if name not in SCAN: raise ValueError(f"unknown key '{name}'")
    scan, ext = SCAN[name]
    flags = KEYEVENTF_SCANCODE | (KEYEVENTF_EXTENDEDKEY if ext else 0) | (KEYEVENTF_KEYUP if up else 0)
    return INPUT(INPUT_KEYBOARD, _U(ki=KEYBDINPUT(0, scan, flags, 0, 0)))

def mouse_event(flags, dx=0, dy=0):
    return INPUT(INPUT_MOUSE, _U(mi=MOUSEINPUT(dx, dy, 0, flags, 0, 0)))

def press(name, hold=0.05):
    # Games poll key state once per frame: keep the key down across a few frames.
    send(key_event(name, False)); time.sleep(hold); send(key_event(name, True)); time.sleep(0.1)

def move(dx, dy, seconds=0.0):
    steps = max(1, int(seconds * 250))
    done_x = done_y = 0
    for i in range(1, steps + 1):
        tx, ty = round(dx * i / steps), round(dy * i / steps)
        send(mouse_event(MOUSEEVENTF_MOVE, tx - done_x, ty - done_y))
        done_x, done_y = tx, ty
        if steps > 1: time.sleep(seconds / steps)

def find_window(pid, timeout=20):
    found = []
    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, _):
        p = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value == pid and user32.IsWindowVisible(hwnd) and user32.GetWindowTextLengthW(hwnd) > 0:
            found.append(hwnd)
        return True
    end = time.time() + timeout
    while time.time() < end:
        found.clear(); user32.EnumWindows(cb, 0)
        if found: return found[0]
        time.sleep(0.25)
    return None

def focus(hwnd):
    user32.ShowWindow(hwnd, 9)
    # A key tap lets a background process take the foreground.
    send(key_event("lctrl", False), key_event("lctrl", True))
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.3)

def shot(hwnd, path):
    focus(hwnd)
    r = wintypes.RECT(); user32.GetWindowRect(hwnd, ctypes.byref(r))
    ImageGrab.grab(bbox=(r.left, r.top, r.right, r.bottom), all_screens=True).save(path)
    return f"{path} ({r.right - r.left}x{r.bottom - r.top})"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe"); ap.add_argument("--args", default="")
    ap.add_argument("--process", help="attach to a running process by name (without .exe)")
    ap.add_argument("--steps", required=True)
    ap.add_argument("--close", action="store_true", help="close the app at the end")
    a = ap.parse_args()

    proc = None
    if a.exe:
        log = open(a.exe + ".drive.log", "w")
        proc = subprocess.Popen([a.exe] + a.args.split(), stdout=log, stderr=subprocess.STDOUT)
        pid = proc.pid
    elif a.process:
        out = subprocess.run(["powershell", "-NoProfile", "-Command", f"(Get-Process {a.process} | ? MainWindowHandle -ne 0 | select -First 1).Id"],
                             capture_output=True, text=True).stdout.strip()
        if not out: sys.exit(f"no running process '{a.process}' with a window")
        pid = int(out)
    else:
        sys.exit("pass --exe or --process")

    hwnd = find_window(pid)
    if not hwnd:
        code = proc.poll() if proc else None
        sys.exit(f"no window appeared (process exit code: {code}); see {a.exe}.drive.log" if proc else "no window")
    focus(hwnd)

    crashed = False
    try:
        for raw in [s.strip() for s in a.steps.split(";") if s.strip()]:
            if proc and proc.poll() is not None:
                print(f"APP EXITED with code {proc.returncode} before step '{raw}'"); crashed = True; break
            cmd, *p = raw.split()
            if cmd == "wait": time.sleep(float(p[0])); msg = ""
            elif cmd == "key":
                focus(hwnd)
                for _ in range(int(p[1]) if len(p) > 1 else 1): press(p[0].lower())
                msg = ""
            elif cmd == "hold":
                focus(hwnd); send(key_event(p[0].lower(), False)); time.sleep(float(p[1])); send(key_event(p[0].lower(), True)); msg = ""
            elif cmd == "move": move(int(p[0]), int(p[1]), float(p[2]) if len(p) > 2 else 0.0); msg = ""
            elif cmd == "click":
                right = p and p[0] == "right"
                send(mouse_event(MOUSEEVENTF_RIGHTDOWN if right else MOUSEEVENTF_LEFTDOWN)); time.sleep(0.05)
                send(mouse_event(MOUSEEVENTF_RIGHTUP if right else MOUSEEVENTF_LEFTUP)); msg = ""
            elif cmd == "mousedown": send(mouse_event(MOUSEEVENTF_LEFTDOWN)); msg = ""
            elif cmd == "mouseup": send(mouse_event(MOUSEEVENTF_LEFTUP)); msg = ""
            elif cmd == "shot": msg = "saved " + shot(hwnd, p[0])
            else: raise ValueError(f"unknown step '{raw}'")
            print(f"ok: {raw}" + (f" -> {msg}" if msg else ""), flush=True)
    finally:
        running = proc.poll() is None if proc else True
        if proc and not running and not crashed:
            print(f"APP EXITED with code {proc.returncode}"); crashed = proc.returncode != 0
        if crashed and a.exe:
            # Show the app's own output: it usually contains the exception and stack trace.
            try:
                tail = open(a.exe + ".drive.log", encoding="utf-8", errors="replace").read().strip().splitlines()[-25:]
                print("---- app output (last 25 lines) ----")
                print(*(tail or ["(empty)"]), sep="\n")
            except OSError: pass
        if a.close and proc and proc.poll() is None:
            user32.PostMessageW(hwnd, 0x0010, 0, 0)  # WM_CLOSE
            try: proc.wait(3)
            except subprocess.TimeoutExpired: proc.kill()
        print(f"app running: {proc.poll() is None if proc else 'attached'}")
    sys.exit(1 if crashed else 0)

if __name__ == "__main__":
    main()
