#!/usr/bin/env python3
"""Install only the two local E2E bundles at stable, user-visible paths."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

LOCAL_IDENTITY = "6BE782BB-6D3B-41DB-B44B-E6495F3C3A64"


def prepare_bundle(bundle, name, identifier):
    info_path = bundle / "Contents/Info.plist"
    with info_path.open("rb") as file:
        info = plistlib.load(file)
    info.update(CFBundleName=Path(name).stem, CFBundleDisplayName=Path(name).stem,
                AudioOrbitE2ELocalIdentity=LOCAL_IDENTITY,
                CFBundleInfoDictionaryVersion="6.0", LSMinimumSystemVersion="14.2")
    with info_path.open("wb") as file:
        plistlib.dump(info, file)
    identity = os.environ.get("AUDIOORBIT_E2E_SIGN_IDENTITY", "-")
    command = ["/usr/bin/codesign", "--force", "--sign", identity]
    if identity == "-":
        # The default ad-hoc requirement is tied to a code hash. Use
        # a stable local-development identity, scoped to each E2E app.
        command += ["--requirements", f'=designated => identifier "{identifier}" and info[AudioOrbitE2ELocalIdentity] = "{LOCAL_IDENTITY}"']
    subprocess.run(command + [str(bundle)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(bundle)], check=True)


def install(build, destination):
    bundles = [
        (build / "AudioOrbit E2E Driver.app", "AudioOrbit E2E Driver.app", "me.snowzjx.AudioOrbit.E2EDriver"),
        (build / "DerivedData/Build/Products/Debug/AudioOrbit.app", "AudioOrbit E2E.app", "me.snowzjx.AudioOrbit.E2E"),
    ]
    # Validate all inputs/destinations before replacing any bundle. Never
    # overwrite the production app or an unrelated same-named application.
    for source, name, identifier in bundles:
        with (source / "Contents/Info.plist").open("rb") as file:
            assert plistlib.load(file)["CFBundleIdentifier"] == identifier, "Unexpected source bundle identity"
        target = destination / name
        if target.exists():
            with (target / "Contents/Info.plist").open("rb") as file:
                assert plistlib.load(file)["CFBundleIdentifier"] == identifier, "Refusing to replace an unrelated app"
    destination.mkdir(parents=True, exist_ok=True)
    for source, name, identifier in bundles:
        prepare_bundle(source, name, identifier)
        with tempfile.TemporaryDirectory(prefix=".e2e-install-", dir=destination) as temporary:
            staged = Path(temporary) / name
            subprocess.run(["/usr/bin/ditto", str(source), str(staged)], check=True)
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(staged)], check=True)
            target = destination / name
            backup = Path(temporary) / "previous.app"
            if target.exists():
                target.rename(backup)
            try:
                staged.rename(target)
            except BaseException:
                if backup.exists():
                    backup.rename(target)
                raise
            print(f"Installed: {target}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--apps-dir", required=True, type=Path)
    args = parser.parse_args()
    install(args.build_dir, args.apps_dir.expanduser())
