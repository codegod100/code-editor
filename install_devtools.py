#!/usr/bin/env python3
"""Install the Dart/Flutter DevTools command-line package for local development."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


def pub_cache_bin() -> Path:
    """Return the platform-specific directory containing Dart global executables."""
    if "PUB_CACHE" in os.environ:
        return Path(os.environ["PUB_CACHE"]) / "bin"
    if sys.platform == "win32":
        app_data = os.environ.get("APPDATA")
        if not app_data:
            raise RuntimeError("APPDATA is required to locate the Dart pub cache on Windows.")
        return Path(app_data) / "Pub" / "Cache" / "bin"
    return Path.home() / ".pub-cache" / "bin"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install the Dart/Flutter DevTools command-line package."
    )
    parser.parse_args()

    dart = shutil.which("dart")
    if dart is None:
        print(
            "Dart SDK was not found on PATH. Install Flutter (which includes Dart) or Dart, "
            "then run this script again.",
            file=sys.stderr,
        )
        return 1

    try:
        subprocess.run([dart, "pub", "global", "activate", "devtools"], check=True)
    except subprocess.CalledProcessError as error:
        print(f"DevTools installation failed with exit code {error.returncode}.", file=sys.stderr)
        return error.returncode

    executable_directory = pub_cache_bin()
    print("DevTools installed successfully.")
    print(f"Ensure this directory is on PATH: {executable_directory}")
    print("Start it with: devtools")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
