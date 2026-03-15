"""
build_exe.py
============
Build script to create a standalone .exe using PyInstaller.

Usage:
    python build_exe.py

Output:
    dist/StardewModConfigurator.exe   (Windows)
    dist/StardewModConfigurator       (macOS/Linux)
"""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent


def main() -> None:
    script = HERE / "stardew_mod_configurator.py"
    if not script.exists():
        print(f"ERROR: {script} not found")
        sys.exit(1)

    cmd = [
        sys.executable,
        "-m",
        "PyInstaller",
        "--onefile",
        "--windowed",
        "--name",
        "StardewModConfigurator",
        "--clean",
        str(script),
    ]

    print("Running PyInstaller…")
    print(" ".join(cmd))
    result = subprocess.run(cmd, cwd=str(HERE))
    if result.returncode == 0:
        print("\n✓ Build successful!")
        dist = HERE / "dist" / "StardewModConfigurator"
        if sys.platform == "win32":
            dist = dist.with_suffix(".exe")
        print(f"  Output: {dist}")
    else:
        print("\n✗ Build failed.")
        sys.exit(result.returncode)


if __name__ == "__main__":
    main()
