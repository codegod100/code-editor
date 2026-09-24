#!/usr/bin/env python3
"""Configure the Modal secret and GitHub workflow-run webhook for CI repair.

The script uses the currently authenticated GitHub CLI account only to manage
repository webhooks. It sends the repair bot token and webhook secret to Modal
through a mode-0600 temporary JSON file, which is deleted before exit.
"""

import argparse
import getpass
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlparse


SECRET_NAME = "code-editor-ci-repair"
DEFAULT_REPOSITORY = "codegod100/code-editor"
DEFAULT_APP_URL = "https://codegod100--cloud-code-editor-serve.modal.run"


def run(command: list[str], *, input_value: str | None = None, capture: bool = False) -> str:
    result = subprocess.run(
        command,
        input=input_value,
        text=True,
        capture_output=capture,
        check=True,
    )
    return result.stdout if capture else ""


def secret_values(repositories: list[str], *, prompt_for_github_token: bool) -> dict[str, str]:
    if prompt_for_github_token:
        print("Enter a dedicated fine-grained GitHub token for CI repair.")
        github_token = getpass.getpass("GitHub bot token: ").strip()
    else:
        # gh reads this from the logged-in account's credential store. Capture
        # it rather than printing it, then pass it only to Modal's secret API.
        github_token = run(["gh", "auth", "token"], capture=True).strip()
    values = {
        "GH_TOKEN": github_token,
        "WEBHOOK_SECRET": secrets.token_urlsafe(48),
        "CI_REPAIR_REPOSITORIES": ",".join(repositories),
    }
    if not github_token:
        raise ValueError("GitHub token is empty; log in with gh or use --prompt-github-token")
    return values


def configure_modal_secret(values: dict[str, str], environment: str | None) -> None:
    descriptor, descriptor_name = tempfile.mkstemp(prefix="code-editor-ci-repair-", suffix=".json")
    path = Path(descriptor_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            # This avoids Modal CLI's optional python-dotenv dependency while
            # keeping secrets out of command arguments and standard output.
            json.dump(values, stream)
        command = ["modal", "secret", "create", SECRET_NAME, "--force", "--from-json", str(path)]
        if environment:
            command.extend(["--env", environment])
        run(command)
    finally:
        path.unlink(missing_ok=True)


def configure_webhook(repository: str, endpoint: str, secret: str) -> None:
    hooks = json.loads(run(["gh", "api", f"repos/{repository}/hooks"], capture=True))
    existing = next(
        (hook for hook in hooks if hook.get("config", {}).get("url") == endpoint), None
    )
    payload = {
        "name": "web",
        "active": True,
        "events": ["workflow_run"],
        "config": {
            "url": endpoint,
            "content_type": "json",
            "secret": secret,
            "insecure_ssl": "0",
        },
    }
    descriptor, descriptor_name = tempfile.mkstemp(prefix="code-editor-github-hook-", suffix=".json")
    path = Path(descriptor_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream)
        if existing:
            command = ["gh", "api", "--method", "PATCH", f"repos/{repository}/hooks/{existing['id']}"]
        else:
            command = ["gh", "api", "--method", "POST", f"repos/{repository}/hooks"]
        run([*command, "--input", str(path), "--silent"])
    finally:
        path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Configure CI repair's Modal secret and GitHub webhook.")
    parser.add_argument("--repo", action="append", help="Repository to enable, repeat for multiple repositories")
    parser.add_argument("--app-url", default=DEFAULT_APP_URL, help="Deployed application URL (default: %(default)s)")
    parser.add_argument("--environment", help="Modal environment for the secret")
    parser.add_argument(
        "--prompt-github-token",
        action="store_true",
        help="prompt for a dedicated GitHub bot token instead of using the active gh login",
    )
    args = parser.parse_args()
    repositories = args.repo or [DEFAULT_REPOSITORY]
    if any("/" not in repository or repository.count("/") != 1 for repository in repositories):
        parser.error("each --repo must be in owner/repository form")
    parsed_url = urlparse(args.app_url)
    if parsed_url.scheme != "https" or not parsed_url.netloc or parsed_url.query or parsed_url.fragment:
        parser.error("--app-url must be an HTTPS origin without a query or fragment")
    endpoint = args.app_url.rstrip("/") + "/webhooks/github"
    if not shutil.which("gh") or not shutil.which("modal"):
        print("Both GitHub CLI (gh) and Modal CLI (modal) are required.", file=sys.stderr)
        return 1
    try:
        run(["gh", "auth", "status", "--hostname", "github.com"])
        values = secret_values(repositories, prompt_for_github_token=args.prompt_github_token)
        configure_modal_secret(values, args.environment)
        for repository in repositories:
            configure_webhook(repository, endpoint, values["WEBHOOK_SECRET"])
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"Unable to configure CI repair webhook: {error}", file=sys.stderr)
        return 1
    print(f"Configured Modal secret {SECRET_NAME} and Workflow runs webhook(s) for {', '.join(repositories)}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
