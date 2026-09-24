#!/usr/bin/env python3
"""Configure the Modal credentials required by the deployment workflow.

Use a dedicated Modal service-user token, not an interactive personal token:

    python3 scripts/configure_modal_github_secrets.py
"""

import argparse
import getpass
import shutil
import subprocess
import sys


SECRET_NAMES = ("MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET")


def run(command: list[str], *, input_value: str | None = None) -> None:
    subprocess.run(command, input=input_value, text=True, check=True)


def prompt_for_secret_values() -> dict[str, str]:
    print("Enter a Modal service-user token with Contributor access.")
    values = {
        "MODAL_TOKEN_ID": getpass.getpass("Modal token ID: ").strip(),
        "MODAL_TOKEN_SECRET": getpass.getpass("Modal token secret: ").strip(),
    }
    missing = [name for name, value in values.items() if not value]
    if missing:
        names = ", ".join(missing)
        raise ValueError(f"Both prompted values are required: {names}")
    return values


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Set Modal deployment credentials as GitHub Actions secrets."
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
        values = prompt_for_secret_values()
        run(["gh", "auth", "status", "--hostname", "github.com"])
        for name, value in values.items():
            # gh reads the secret body from stdin, avoiding its inclusion in
            # the command line or this script's output.
            run(["gh", "secret", "set", name, "--repo", args.repo], input_value=value)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Unable to configure GitHub Actions secrets: {error}", file=sys.stderr)
        return 1

    print(f"Configured {', '.join(SECRET_NAMES)} for {args.repo}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
