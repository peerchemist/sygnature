#!/usr/bin/env python3
"""Sign real Mach-O files and their enclosing bundles from the inside out."""

import os
from pathlib import Path
import plistlib
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True)


def main():
    app = Path(sys.argv[1]).resolve()
    entitlements = Path(sys.argv[2]).resolve()
    identity = os.environ["MACOS_SIGNING_IDENTITY"]
    team = os.environ["APPLE_TEAM_ID"]
    with entitlements.open("rb") as stream:
        if plistlib.load(stream).get("com.apple.security.get-task-allow"):
            raise SystemExit("Distribution entitlements must not enable debugging.")

    # Do not follow framework symlinks or sign the same binary more than once.
    # Include native assets even when Flutter puts them outside Frameworks.
    targets = set()
    for root, directories, files in os.walk(app, followlinks=False):
        directory = Path(root)
        if directory.suffix in {".app", ".framework", ".xpc", ".appex", ".bundle"}:
            if not directory.is_symlink():
                # CocoaPods also installs resource-only .bundle directories.
                # They are sealed by their parent, not signed as executable code.
                if directory.suffix != ".bundle" or any(
                    (directory / location).is_file()
                    and plistlib.loads((directory / location).read_bytes()).get("CFBundleExecutable")
                    for location in ("Contents/Info.plist", "Info.plist")
                ):
                    targets.add(directory)
        for name in files:
            path = directory / name
            if not path.is_symlink() and "Mach-O" in run("file", "--brief", str(path)):
                targets.add(path)

    options = ["--force", "--sign", identity, "--timestamp", "--options", "runtime"]
    if os.environ.get("MACOS_SIGNING_KEYCHAIN"):
        options += ["--keychain", os.environ["MACOS_SIGNING_KEYCHAIN"]]
    # Files before their parent bundle; deepest bundles before enclosing bundles.
    for target in sorted(targets, key=lambda path: (-len(path.parts), str(path))):
        args = options[:]
        if target == app:
            args += ["--entitlements", str(entitlements)]
        subprocess.run(["codesign", *args, str(target)], check=True)

    # Check every component, including dylibs not covered by standard nesting.
    for target in sorted(targets):
        subprocess.run(["codesign", "--verify", "--strict", str(target)], check=True)
        details = run("codesign", "--display", "--verbose=4", str(target))
        if f"TeamIdentifier={team}\n" not in details:
            raise SystemExit(f"Unexpected signing team: {target}")
        if "Authority=Developer ID Application:" not in details or "Timestamp=" not in details:
            raise SystemExit(f"Missing timestamped Developer ID signature: {target}")
        if "runtime" not in details.split("flags=", 1)[-1].splitlines()[0]:
            raise SystemExit(f"Hardened runtime is missing: {target}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


if __name__ == "__main__":
    main()
