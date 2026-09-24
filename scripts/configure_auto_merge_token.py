#!/usr/bin/env python3
"""Configure the auto-merge GitHub Actions secret from GitHub CLI auth.

The token is obtained from the authenticated GitHub CLI account and passed to
GitHub CLI on standard input. It is never read from an environment variable,
command-line argument, or file.

Usage:
    python3 scripts/configure_auto_merge_token.py
"""

import argparse
import shutil
import subprocess
import sys


SECRET_NAME = "AUTO_MERGE_TOKEN"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Set the GitHub Actions auto-merge token from GitHub CLI auth."
    )
    parser.add_argument(
        "--repo",
        default="codegod100/code-editor",
        help="GitHub repository to configure (default: %(default)s)",
    )
    args = parser.parse_args()

    if not shutil.which("gh"):
        print("GitHub CLI (gh) is required but was not found on PATH.", file=sys.stderr)
        return 1

    try:
        subprocess.run(
            ["gh", "auth", "status", "--hostname", "github.com"], check=True
        )
        token_result = subprocess.run(
            ["gh", "auth", "token", "--hostname", "github.com"],
            check=True,
            capture_output=True,
            text=True,
        )
        token = token_result.stdout.strip()
        if not token:
            print("GitHub CLI returned an empty token.", file=sys.stderr)
            return 1
        # gh reads the secret value from stdin, keeping it out of the command
        # line, environment, files, and script output.
        subprocess.run(
            ["gh", "secret", "set", SECRET_NAME, "--repo", args.repo],
            input=token,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Unable to configure {SECRET_NAME}: {error}", file=sys.stderr)
        return 1

    print(f"Configured {SECRET_NAME} for {args.repo} from the authenticated GitHub CLI token.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
