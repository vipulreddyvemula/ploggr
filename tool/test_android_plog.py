"""Drive the M3 app and system permission UI on a disposable Android emulator."""
import re
import subprocess
import sys
import time
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


def tap(label=None, *, resource=None, pattern=None):
    def target():
        output = adb("exec-out", "uiautomator", "dump", "/dev/tty", check=False)
        start, end = output.find("<hierarchy"), output.rfind("</hierarchy>")
        if start < 0 or end < 0:
            return None
        for node in ET.fromstring(output[start:end + len("</hierarchy>")]).iter("node"):
            fields = node.attrib
            labels = [fields.get("text", ""), fields.get("content-desc", "")]
            if (resource and fields["resource-id"].endswith("/" + resource) or
                    label and label in labels or
                    pattern and any(re.search(pattern, text) for text in labels)):
                x1, y1, x2, y2 = map(int, re.findall(r"-?\d+", fields["bounds"]))
                if x2 > x1 and y2 > y1:
                    return str((x1 + x2) // 2), str((y1 + y2) // 2)
        return None

    name = label or resource or pattern
    print("Checking Android UI:", name, flush=True)
    adb("shell", "input", "tap", *until(target, name))


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
    tap("Start Plog Session")
    tap(resource="permission_deny_button")
    stage("denied")
    tap("Retry GPS")
    tap(resource="permission_allow_foreground_only_button")
    stage("tracking")
    for index, longitude in enumerate(["-122.084", "-122.083"]):
        def deliver():
            adb("emu", "geo", "fix", longitude, "37.422")
            time.sleep(2)
            return marker("fix-" + str(index)) == "ok"
        until(deliver, "recorded GPS fix " + str(index))
elif PHASE == "offline":
    tap("Finish Plog")
    stage("frozen")
    adb("emu", "geo", "fix", "-122.080", "37.422")
    adb("shell", "run-as", PACKAGE, "touch", "cache/plog-extra-fix")
    until(lambda: marker("checkpoint").startswith("{"), "durable finish")
    adb("shell", "am", "force-stop", PACKAGE)
elif PHASE == "restore":
    start_app()
    stage("reopened")
    tap("Start Plog Session")
    tap("Retry save")
    stage("verified")
    tap("View activity")
    tap(pattern=r"\d+ s · [\d.]+ m")
    tap("All activities")
else:
    raise ValueError("Unknown test phase")
