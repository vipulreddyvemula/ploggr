"""Drive the Plog app, permissions, photo picker and camera on a disposable Android emulator."""
import re
import subprocess
import sys
import time
from uuid import uuid4
import xml.etree.ElementTree as ET

DEVICE, PHASE = sys.argv[1:]
PACKAGE = "com.example.ploggr"


def adb(*args, check=True):
    return subprocess.run(["adb", "-s", DEVICE, *args], text=True, capture_output=True,
                          timeout=15, check=check).stdout.strip()


def marker(name):
    return adb("shell", "run-as", PACKAGE, "cat", "cache/plog-" + name, check=False)


def until(operation, description, timeout=75):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        error = marker("failure")
        if error and "No such file" not in error:
            raise RuntimeError(error)
        value = operation()
        if value:
            return value
        time.sleep(0.4)
    raise RuntimeError("Timed out waiting for " + description)


def nodes():
    output = adb("exec-out", "uiautomator", "dump", "/dev/tty", check=False)
    start, end = output.find("<hierarchy"), output.rfind("</hierarchy>")
    if start < 0 or end < 0:
        return []
    return [n.attrib for n in ET.fromstring(output[start:end + len("</hierarchy>")]).iter("node")]


def target(fields, label=None, resource=None, pattern=None):
    for node in fields:
        labels = [node.get("text", ""), node.get("content-desc", "")]
        if (resource and node["resource-id"].endswith("/" + resource) or
                label and label in labels or
                pattern and any(re.search(pattern, value) for value in labels)):
            x1, y1, x2, y2 = map(int, re.findall(r"-?\d+", node["bounds"]))
            if x2 > x1 and y2 > y1:
                return str((x1 + x2) // 2), str((y1 + y2) // 2)
    return None


def control(label=None, *, resource=None, pattern=None, click=True):
    name = label or resource or pattern
    print("Checking Android UI:", name, flush=True)
    position = until(lambda: target(nodes(), label, resource, pattern), name)
    if click:
        adb("shell", "input", "tap", *position)


def choose_gallery_photo():
    album = "Ploggr-" + uuid4().hex[:8]
    directory = "/sdcard/Pictures/" + album
    photo = directory + "/garbage.png"
    scan = ("shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", "file://" + photo)
    adb("shell", "mkdir", directory)
    try:
        adb("push", "assets/images/demo/litter.png", photo)
        adb(*scan)
        control("Choose photo")
        control("Collections")
        control("From this device")
        control(album)
        control(resource="icon_thumbnail", pattern=r"^Photo taken on ")
        control("Done")
        control("Garbage photos (1/6)", click=False)
    finally:
        adb("shell", "rm", "-f", photo)
        adb(*scan)
        adb("shell", "rmdir", directory)


def capture():
    def shutter():
        fields = nodes()
        button = target(fields, resource="shutter_button")
        if button:
            return button
        for label in ["Next", "No thanks", "Got it", "While using the app"]:
            button = target(fields, label)
            if button:
                adb("shell", "input", "tap", *button)
                break
        return None
    print("Checking Android camera shutter", flush=True)
    adb("shell", "input", "tap", *until(shutter, "camera shutter"))
    control(resource="done_button")


def start_app():
    adb("shell", "am", "start", "-n", PACKAGE + "/.MainActivity")


def stage(name):
    return until(lambda: marker(name) == "ok", name)


if PHASE == "track":
    adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
    adb("shell", "wm", "dismiss-keyguard")
    adb("emu", "geo", "fix", "-122.084", "37.422")
    start_app()
    stage("ready")
    control("Start Plog Session")
    control(resource="permission_deny_button")
    stage("denied")
    control("Retry GPS")
    control(resource="permission_allow_foreground_only_button")
    stage("tracking")
    for index, longitude in enumerate(["-122.084", "-122.083"]):
        def deliver():
            adb("emu", "geo", "fix", longitude, "37.422")
            time.sleep(2)
            return marker("fix-" + str(index)) == "ok"
        until(deliver, "recorded GPS fix " + str(index))
elif PHASE == "offline":
    control("Finish Plog")
    choose_gallery_photo()
    control("Take photo")
    capture()
    control("Garbage photos (2/6)", click=False)
    control("Save Plog")
    stage("frozen")
    adb("emu", "geo", "fix", "-122.080", "37.422")
    adb("shell", "run-as", PACKAGE, "touch", "cache/plog-extra-fix")
    until(lambda: marker("checkpoint").startswith("{"), "durable finish")
    adb("shell", "am", "force-stop", PACKAGE)
elif PHASE == "restore":
    start_app()
    stage("reopened")
    control("Start Plog Session")
    control("Retry save")
    stage("completed")
elif PHASE == "retrieve":
    adb("shell", "run-as", PACKAGE, "touch", "cache/plog-storage-restarted")
    stage("verified")
    control("View activity")
    control(pattern=r"\d+ s · [\d.]+ m")
    control(pattern=r"Saved garbage photo 1", click=False)
    if not target(nodes(), pattern=r"Saved garbage photo 2"):
        width, height = map(int, re.findall(r"(\d+)x(\d+)", adb("shell", "wm", "size"))[-1])
        adb("shell", "input", "swipe", str(width // 2), str(3 * height // 4),
            str(width // 2), str(height // 3), "350")
    control(pattern=r"Saved garbage photo 2", click=False)
else:
    raise ValueError("Unknown test phase")
