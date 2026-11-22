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
                          timeout=30, check=check).stdout.strip()


def marker(name):
    return adb("shell", "run-as", PACKAGE, "cat", "cache/plog-" + name, check=False)


def until(operation, description, timeout=90):
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
        labels = [node.get(key, "") for key in ("text", "content-desc", "hint")]
        if node.get("enabled") == "false":
            continue
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


def swipe(up=True):
    size = adb("shell", "wm", "size")
    width, height = map(int, re.findall(r"(\d+)x(\d+)", size)[-1])
    start, end = (3 * height // 4, height // 3) if up else (height // 3, 3 * height // 4)
    adb("shell", "input", "swipe", str(width // 5), str(start), str(width // 5), str(end), "400")


def reveal(label, *, pattern=None, up=True, click=True):
    for _ in range(6):
        position = target(nodes(), label=label, pattern=pattern)
        if position:
            if click:
                adb("shell", "input", "tap", *position)
            return
        swipe(up)
    control(label, pattern=pattern, click=click)


def enter_field(label, value):
    control(pattern=label)
    adb("shell", "input", "text", value)


def choose_gallery_photo(source="Choose photo", expected_total=1):
    album = "Ploggr-" + uuid4().hex[:8]
    directory = "/sdcard/Pictures/" + album
    photo = directory + "/garbage.png"
    scan = ("shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", "file://" + photo)
    adb("shell", "mkdir", directory)
    try:
        adb("push", "assets/images/demo/litter.png", photo)
        adb(*scan)
        control(source)
        def picker_layout():
            tree = nodes()
            if target(tree, label="Collections"):
                return "collections"
            if target(tree, label="Albums") and target(tree, resource="icon_thumbnail"):
                return "recent"
            return None

        if until(picker_layout, "system photo picker") == "collections":
            control("Collections")
            control("From this device")
            control(album)
        # The compact Android picker opens directly on Recent. The disposable
        # emulator contains only the temporary photo pushed by this helper.
        control(resource="icon_thumbnail", pattern=r"^Photo taken on ")

        def confirmed():
            tree = nodes()
            if target(tree, pattern=rf"^(Pickup photos|Photos) \({expected_total}/6\)") or target(tree, label="Did you clean up this spot?"):
                return True
            done = target(tree, label="Done")
            if done:
                adb("shell", "input", "tap", *done)
            return False

        until(confirmed, "selected gallery photo")
    finally:
        adb("shell", "rm", "-f", photo)
        adb(*scan)
        adb("shell", "rmdir", directory)


def camera_ready():
    def ready():
        tree = nodes()
        allow = target(tree, resource="permission_allow_foreground_only_button")
        if allow:
            adb("shell", "input", "tap", *allow)
        return target(tree, label="Take picture")
    until(ready, "in-app camera")


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
    control("Report")
    choose_gallery_photo("Choose photo")
    control("Choose spot")
    control("Search a park, street or landmark", click=False)
    width, height = map(int, re.findall(r"(\d+)x(\d+)", adb("shell", "wm", "size"))[-1])
    def choose_map_point():
        adb("shell", "input", "tap", str(width // 2), str(height // 2))
        return target(nodes(), label="Use this spot")
    until(choose_map_point, "movable map pin")
    control("Use this spot")
    reveal(None, pattern=r"Notes \(optional\)")
    adb("shell", "input", "text", "Lakeside")
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    control("Post report")
    control("Litter Map", click=False)
    adb("shell", "run-as", PACKAGE, "touch", "cache/plog-posted")
    stage("walker")
    control("Map")
    control("List")
    reveal(None, pattern=r"Lakeside")
    control("Plog this spot")
    control(resource="permission_deny_button")
    stage("denied")
    reveal("Retry GPS")
    control(resource="permission_allow_foreground_only_button")
    def tracking_ready():
        if marker("tracking") == "ok":
            return True
        permission = target(nodes(), resource="permission_allow_button")
        if permission:
            adb("shell", "input", "tap", *permission)
        return False
    until(tracking_ready, "active GPS tracking")
    until(lambda: "Plog in progress" in adb("shell", "dumpsys", "notification", "--noredact"),
          "ongoing Plog notification")
    for index, longitude in enumerate(["-122.084", "-122.083"]):
        def deliver():
            adb("emu", "geo", "fix", longitude, "37.422")
            time.sleep(2)
            return marker("fix-" + str(index)) == "ok"
        if index == 1:
            adb("shell", "input", "keyevent", "KEYCODE_SLEEP")
        until(deliver, "recorded GPS fix " + str(index))
    adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
    adb("shell", "wm", "dismiss-keyguard")
elif PHASE == "offline":
    reveal("Add pickup")
    camera_ready()
    control("Take picture")
    control("Yes, it’s clean")
    reveal("Choose from gallery", click=False)
    choose_gallery_photo("Choose from gallery", expected_total=2)
    reveal("Finish Plog", up=False)
    control("Finish Plog")
    reveal("Save Plog")
    stage("frozen")
    adb("emu", "geo", "fix", "-122.080", "37.422")
    adb("shell", "run-as", PACKAGE, "touch", "cache/plog-extra-fix")
    until(lambda: marker("checkpoint").startswith("{"), "durable finish")
    adb("shell", "am", "force-stop", PACKAGE)
elif PHASE == "restore":
    start_app()
    stage("reopened")
    control(pattern=r"^(Start|Resume) Plog Session$")
    reveal("Retry save")
    stage("completed")
elif PHASE == "retrieve":
    adb("shell", "run-as", PACKAGE, "touch", "cache/plog-storage-restarted")
    stage("verified")
    control("Plog details", click=False)
    reveal(None, pattern=r"Saved pickup photo 1", click=False)
    if not target(nodes(), pattern=r"Saved pickup photo 2"):
        width, height = map(int, re.findall(r"(\d+)x(\d+)", adb("shell", "wm", "size"))[-1])
        adb("shell", "input", "swipe", str(width // 2), str(3 * height // 4),
            str(width // 2), str(height // 3), "350")
    reveal(None, pattern=r"Saved pickup photo 2", click=False)
else:
    raise ValueError("Unknown test phase")
