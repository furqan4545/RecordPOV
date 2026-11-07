#!/usr/bin/env python3
"""Use the installed JDK/Android SDK without changing shell profiles or creating emulators."""
import argparse
import os
import shutil
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("command", choices=["build", "test", "check"])
args = parser.parse_args()
env = os.environ.copy()
sdk = Path(env.get("ANDROID_HOME") or env.get("ANDROID_SDK_ROOT") or Path.home() / "Library/Android/sdk")
if not sdk.is_dir():
    raise SystemExit("Set ANDROID_HOME to your existing Android SDK directory.")
java_home = env.get("JAVA_HOME")
if java_home:
    candidates = [Path(java_home)]
else:
    candidates = [Path("/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"),
                  Path("/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home")]
    if Path("/usr/libexec/java_home").exists():
        result = subprocess.run(["/usr/libexec/java_home", "-v", "17"], capture_output=True, text=True)
        if result.returncode == 0:
            candidates.append(Path(result.stdout.strip()))
selected = next((candidate for candidate in candidates if (candidate / "bin/java").is_file()), None)
if selected:
    env["JAVA_HOME"] = str(selected)
    env["PATH"] = str(selected / "bin") + os.pathsep + env.get("PATH", "")
elif java_home or not shutil.which("java"):
    raise SystemExit("Set JAVA_HOME to an installed JDK 17 or newer.")
env["ANDROID_HOME"] = str(sdk)
if args.command == "check":
    subprocess.run(["java", "-version"], env=env, check=True)
    print("Android SDK:", sdk)
else:
    task = ":app:assembleDebug" if args.command == "build" else ":app:testDebugUnitTest"
    subprocess.run([str(root / "apps/android/gradlew"), "-p", str(root / "apps/android"), task],
                   cwd=root, env=env, check=True)
