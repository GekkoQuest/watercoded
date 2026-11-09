#!/usr/bin/env python3
"""Copy the existing app-specific Sparkle key from Keychain to GitHub securely."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
os.chdir(root)
tools = subprocess.check_output(["scripts/sparkle-tools.sh"], text=True).strip()
account = "dev.watercoded.app"
subprocess.run([f"{tools}/generate_keys", "--account", account], check=True)
public_key = subprocess.check_output(
    [f"{tools}/generate_keys", "--account", account, "-p"], text=True
).strip()
if f"SUPublicEDKey: {public_key}" not in (root / "project.yml").read_text():
    raise SystemExit("Key does not match project.yml. Do not replace a released app's key.")
with tempfile.TemporaryDirectory(prefix="watercoded-signing-") as directory:
    os.chmod(directory, 0o700)
    path = Path(directory) / "private-key"
    subprocess.run(
        [f"{tools}/generate_keys", "--account", account, "-x", str(path)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    path.chmod(0o600)
    with path.open("rb") as key:
        subprocess.run(
            ["gh", "secret", "set", "SPARKLE_PRIVATE_KEY", "--repo", "GekkoQuest/watercoded"],
            stdin=key,
            check=True,
        )
print("Signing key stored in macOS Keychain and GitHub Actions secret.")
