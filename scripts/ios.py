#!/usr/bin/env python3
"""Build/test/run on an existing iPhone 17. This script never creates simulators."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("command", choices=["build", "test", "run", "screenshot"])
parser.add_argument("--output", default="docs/screenshots/ios-home.png")
args = parser.parse_args()
inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
devices = [device for runtime in inventory["devices"].values() for device in runtime
           if device.get("name") == "iPhone 17" and device.get("isAvailable", True)]
if not devices:
    raise SystemExit("The existing iPhone 17 simulator is unavailable. No replacement was created.")
devices.sort(key=lambda device: device.get("state") != "Booted")
device = devices[0]
derived = Path.home() / "Library/Developer/Xcode/DerivedData/Roast-Local"

def run(command):
    subprocess.run(command, cwd=root, check=True)

if args.command in ("run", "test", "screenshot"):
    if device["state"] != "Booted":
        run(["xcrun", "simctl", "boot", device["udid"]])
    run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"])

if args.command != "screenshot":
    # Xcode can spend several minutes collecting simulator diagnostics even
    # after a passing run. Test failures and their normal logs remain visible.
    diagnostic_options = ["-collect-test-diagnostics", "never"] if args.command == "test" else []
    run(["xcodebuild", "-project", "apps/ios/Roast.xcodeproj", "-scheme", "Roast",
         "-destination", f"platform=iOS Simulator,id={device['udid']}",
         "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO",
         "-maximum-concurrent-test-simulator-destinations", "1", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-",
         *diagnostic_options,
         "test" if args.command == "test" else "build"])
if args.command == "run":
    app = derived / "Build/Products/Debug-iphonesimulator/Roast.app"
    with (app / "Info.plist").open("rb") as file:
        bundle_id = plistlib.load(file)["CFBundleIdentifier"]
    run(["xcrun", "simctl", "install", device["udid"], str(app)])
    run(["xcrun", "simctl", "launch", device["udid"], bundle_id])
    run(["open", "-a", "Simulator"])
if args.command == "screenshot":
    target = root / args.output
    target.parent.mkdir(parents=True, exist_ok=True)
    run(["xcrun", "simctl", "io", device["udid"], "screenshot", str(target)])
