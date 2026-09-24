#!/usr/bin/env python3
"""Set the digest-pinned CI image used by the deployment workflow.

Example:
    python3 scripts/set_ci_image_digest.py

The authenticated GitHub CLI account must be permitted to manage Actions
variables for the repository.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


API_ROOT = "https://api.github.com"
VARIABLE_NAME = "CODE_EDITOR_CI_IMAGE_DIGEST"
DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}\Z")
REPOSITORY_PATTERN = re.compile(r"[^/\s]+/[^/\s]+\Z")


class GitHubApiError(RuntimeError):
    """A GitHub API request did not complete successfully."""

    def __init__(self, message: str, *, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create or update the CI image digest GitHub Actions variable."
    )
    parser.add_argument(
        "--repo",
        help="GitHub repository in OWNER/REPOSITORY form (current checkout when omitted)",
    )
    parser.add_argument(
        "--digest",
        help="Published code-editor-ci image digest (resolved from the v1 image tag when omitted)",
    )
    return parser.parse_args()


def request(
    method: str, url: str, token: str, payload: dict[str, str] | None = None
) -> tuple[int, Any | None]:
    body = json.dumps(payload).encode() if payload is not None else None
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "User-Agent": "code-editor-ci-image-digest-script",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if body is not None:
        headers["Content-Type"] = "application/json"

    try:
        with urlopen(Request(url, data=body, headers=headers, method=method)) as response:
            response_body = response.read()
            return response.status, json.loads(response_body) if response_body else None
    except HTTPError as error:
        response_body = error.read().decode("utf-8", errors="replace")
        try:
            message = json.loads(response_body).get("message", response_body)
        except json.JSONDecodeError:
            message = response_body
        raise GitHubApiError(
            f"GitHub API returned HTTP {error.code}: {message}", status=error.code
        ) from error
    except URLError as error:
        raise GitHubApiError(f"Could not reach GitHub API: {error.reason}") from error


def github_cli_token() -> str:
    if not shutil.which("gh"):
        raise GitHubApiError("GitHub CLI (gh) is required but was not found on PATH.")
    try:
        result = subprocess.run(
            ["gh", "auth", "token", "--hostname", "github.com"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise GitHubApiError(
            "Unable to obtain an authenticated GitHub CLI token. "
            "Run 'gh auth login -h github.com' first."
        ) from error

    token = result.stdout.strip()
    if not token:
        raise GitHubApiError(
            "GitHub CLI returned an empty token. Run 'gh auth login -h github.com' first."
        )
    return token


def github_cli_repository() -> str:
    try:
        result = subprocess.run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise GitHubApiError(
            "Unable to determine the current GitHub repository. "
            "Run this from its checkout or pass --repo OWNER/REPOSITORY."
        ) from error
    repository = result.stdout.strip()
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise GitHubApiError("GitHub CLI returned an invalid repository name.")
    return repository


def refresh_github_cli_packages_scope() -> None:
    """Request the package-read scope needed to resolve the v1 image digest."""
    try:
        subprocess.run(
            ["gh", "auth", "refresh", "--hostname", "github.com", "--scopes", "read:packages"],
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise GitHubApiError(
            "GitHub CLI could not add the read:packages scope. "
            "Complete the gh auth refresh prompt and rerun this script."
        ) from error


def published_ci_image_digest(repository: str, token: str) -> str:
    """Return the immutable digest currently assigned to this repository's v1 image."""
    package_name = f"{repository.partition('/')[2]}-ci"
    status, versions = request(
        "GET",
        f"{API_ROOT}/user/packages/container/{package_name}/versions?per_page=100",
        token,
    )
    if status != 200 or not isinstance(versions, list):
        raise GitHubApiError("GitHub returned an unexpected CI image version response.")

    for version in versions:
        if not isinstance(version, dict):
            continue
        metadata = version.get("metadata")
        container = metadata.get("container") if isinstance(metadata, dict) else None
        tags = container.get("tags") if isinstance(container, dict) else None
        digest = version.get("name")
        if isinstance(tags, list) and "v1" in tags and isinstance(digest, str):
            return digest
    raise GitHubApiError(
        f"No version tagged v1 was found for the {package_name} container package. "
        "Run Publish CI Base Image first."
    )


def main() -> int:
    args = parse_arguments()
    try:
        token = github_cli_token()
    except GitHubApiError as error:
        print(error, file=sys.stderr)
        return 1

    try:
        repository = args.repo.strip() if args.repo else github_cli_repository()
    except GitHubApiError as error:
        print(error, file=sys.stderr)
        return 1
    if not REPOSITORY_PATTERN.fullmatch(repository):
        print("--repo must have OWNER/REPOSITORY form.", file=sys.stderr)
        return 1

    try:
        digest = args.digest.strip() if args.digest else published_ci_image_digest(repository, token)
    except GitHubApiError as error:
        if error.status == 403 and "read:packages scope" in str(error):
            try:
                print("Requesting GitHub package-read access through gh…")
                refresh_github_cli_packages_scope()
                token = github_cli_token()
                digest = published_ci_image_digest(repository, token)
            except GitHubApiError as refresh_error:
                print(
                    f"Unable to resolve the published CI image digest: {refresh_error}",
                    file=sys.stderr,
                )
                return 1
        else:
            print(f"Unable to resolve the published CI image digest: {error}", file=sys.stderr)
            return 1
    if not digest:
        print("--digest cannot be empty.", file=sys.stderr)
        return 1
    if not DIGEST_PATTERN.fullmatch(digest):
        print(
            "The published CI image digest must be sha256: followed by 64 lowercase hexadecimal characters.",
            file=sys.stderr,
        )
        return 1

    variable_url = f"{API_ROOT}/repos/{repository}/actions/variables/{VARIABLE_NAME}"
    try:
        status, _ = request("GET", variable_url, token)
        if status == 200:
            request("PATCH", variable_url, token, {"name": VARIABLE_NAME, "value": digest})
            action = "Updated"
        else:
            raise GitHubApiError(f"Unexpected status while checking variable: {status}")
    except GitHubApiError as error:
        # GitHub reports a missing Actions variable as 404. Requesting the
        # collection endpoint creates it; any other error must be reported.
        if error.status != 404:
            print(f"Unable to inspect {VARIABLE_NAME}: {error}", file=sys.stderr)
            return 1
        try:
            request(
                "POST",
                f"{API_ROOT}/repos/{repository}/actions/variables",
                token,
                {"name": VARIABLE_NAME, "value": digest},
            )
            action = "Created"
        except GitHubApiError as create_error:
            print(f"Unable to create {VARIABLE_NAME}: {create_error}", file=sys.stderr)
            return 1

    print(f"{action} {VARIABLE_NAME} for {repository}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
