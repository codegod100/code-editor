"""Modal app and ``origin/main`` deployment launcher.

Run ``python3 deploy.py`` to deploy a clean archive of the newest
``origin/main`` revision. The Modal app is evaluated in that archive, so
uncommitted files and an outdated checkout are never released.
"""

import io
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent
ORIGIN_DEPLOY_ENV = "CODE_EDITOR_DEPLOYING_ORIGIN_MAIN"


def run_git(*arguments: str, capture_output: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(
        ("git", *arguments),
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=capture_output,
    )


def deploy_origin_main() -> int:
    """Fetch and deploy the exact current ``origin/main`` tree."""
    try:
        run_git("fetch", "origin", "main")
        revision = run_git("rev-parse", "origin/main", capture_output=True).stdout
        revision = revision.decode().strip()
        archive = run_git("archive", "--format=tar", revision, capture_output=True).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Unable to prepare origin/main for deployment: {error}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="code-editor-deploy-") as temporary:
        release_root = Path(temporary)
        try:
            with tarfile.open(fileobj=io.BytesIO(archive)) as release:
                release.extractall(release_root, filter="data")
        except tarfile.TarError as error:
            print(f"Unable to unpack origin/main revision {revision}: {error}", file=sys.stderr)
            return 1

        deploy_file = release_root / "deploy.py"
        if not deploy_file.is_file():
            print(
                "origin/main does not contain deploy.py; commit and push this file first.",
                file=sys.stderr,
            )
            return 1

        environment = os.environ | {ORIGIN_DEPLOY_ENV: "1"}
        print(f"Deploying origin/main at {revision}")
        try:
            result = subprocess.run(
                ("modal", "deploy", "deploy.py"),
                cwd=release_root,
                env=environment,
                check=False,
            )
        except OSError as error:
            print(f"Unable to run Modal CLI: {error}", file=sys.stderr)
            return 1
        return result.returncode


if __name__ == "__main__" and os.environ.get(ORIGIN_DEPLOY_ENV) != "1":
    raise SystemExit(deploy_origin_main())


import modal


app = modal.App("cloud-code-editor")
projects = modal.Volume.from_name(
    "cloud-code-editor-projects", create_if_missing=True, version=2
)
pocket_id_secret = modal.Secret.from_name(
    "code-editor-pocket-id",
    required_keys=["OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET", "SESSION_SECRET"],
)

image = (
    modal.Image.from_registry(
        "ghcr.io/cirruslabs/flutter:stable", add_python="3.12"
    )
    .apt_install("bash", "git", "gh")
    .pip_install(
        "authlib==1.6.5",
        "fastapi[standard]==0.121.3",
        "itsdangerous==2.2.0",
        "openai-codex==0.156.1",
    )
    .env(
        {
            "APP_URL": "https://codegod100--cloud-code-editor-serve.modal.run",
            "CODEX_HOME": "/projects/.codex",
            "POCKET_ID_ISSUER": "https://codegod100--pocket-id-serve.modal.run",
        }
    )
    .add_local_dir(".", remote_path="/app", copy=True)
    .workdir("/app")
    .run_commands("flutter build web --release --no-wasm-dry-run")
)


@app.function(
    image=image,
    secrets=[pocket_id_secret],
    volumes={"/projects": projects},
    timeout=60 * 60,
    max_containers=1,
)
@modal.concurrent(max_inputs=20)
@modal.asgi_app()
def serve():
    """Serve the editor UI and its project/Codex API from one origin."""
    import asyncio
    import json
    import os
    import re
    import shutil
    import subprocess
    import tempfile
    from pathlib import Path, PurePosixPath

    from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
    from authlib.integrations.starlette_client import OAuth
    from fastapi.responses import JSONResponse, RedirectResponse, StreamingResponse
    from fastapi.staticfiles import StaticFiles
    from openai_codex import ApprovalMode, AsyncCodex, Sandbox
    from starlette.middleware.sessions import SessionMiddleware

    api = FastAPI(title="Cloud Code Editor", docs_url=None, redoc_url=None)
    root = Path("/projects")
    root.mkdir(parents=True, exist_ok=True)
    (root / ".codex").mkdir(parents=True, exist_ok=True)
    project_name = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
    reserved = {".codex", ".system"}
    max_text_bytes = 2 * 1024 * 1024
    mutation_lock = asyncio.Lock()
    active_turns = {}
    agent_runs = {}
    terminal_sessions = {}

    app_url = os.environ["APP_URL"].rstrip("/")
    pocket_id_issuer = os.environ["POCKET_ID_ISSUER"].rstrip("/")
    oauth = OAuth()
    oauth.register(
        name="pocket_id",
        server_metadata_url=f"{pocket_id_issuer}/.well-known/openid-configuration",
        client_id=os.environ["OIDC_CLIENT_ID"],
        client_secret=os.environ["OIDC_CLIENT_SECRET"],
        client_kwargs={
            "scope": "openid profile email groups",
            "code_challenge_method": "S256",
        },
    )

    public_paths = {"/auth/login", "/auth/callback"}

    @api.middleware("http")
    async def require_pocket_id(request: Request, call_next):
        if request.url.path in public_paths or request.session.get("user"):
            return await call_next(request)
        if request.url.path.startswith("/api/"):
            return JSONResponse(
                {"detail": "Pocket ID authentication required"}, status_code=401
            )
        return RedirectResponse("/auth/login", status_code=307)

    # Add this after the authorization middleware so the session is populated
    # before require_pocket_id reads it.
    api.add_middleware(
        SessionMiddleware,
        secret_key=os.environ["SESSION_SECRET"],
        https_only=True,
        same_site="lax",
        max_age=12 * 60 * 60,
    )

    @api.get("/auth/login")
    async def login(request: Request):
        return await oauth.pocket_id.authorize_redirect(
            request,
            f"{app_url}/auth/callback",
        )

    @api.get("/auth/callback")
    async def auth_callback(request: Request):
        try:
            token = await oauth.pocket_id.authorize_access_token(request)
        except Exception as exc:
            raise HTTPException(401, f"Pocket ID login failed: {exc}") from exc
        claims = token.get("userinfo")
        if not claims or not claims.get("sub"):
            raise HTTPException(401, "Pocket ID did not return an authenticated user")
        request.session["user"] = {
            "sub": claims["sub"],
            "name": claims.get("name") or claims.get("preferred_username") or "User",
            "email": claims.get("email"),
            "groups": claims.get("groups", []),
        }
        return RedirectResponse("/", status_code=303)

    @api.get("/auth/logout")
    async def logout(request: Request):
        request.session.clear()
        return RedirectResponse(pocket_id_issuer, status_code=303)

    @api.get("/api/me")
    async def current_user(request: Request):
        return request.session["user"]

    async def commit() -> None:
        await asyncio.to_thread(projects.commit)

    def project_dir(name: str) -> Path:
        if not project_name.fullmatch(name) or name in reserved:
            raise HTTPException(400, "invalid project name")
        path = root / name
        if not path.is_dir():
            raise HTTPException(404, "project not found")
        return path

    def requested_file(project: Path, value: str) -> Path:
        relative = PurePosixPath(value)
        if relative.is_absolute() or not relative.parts or ".." in relative.parts:
            raise HTTPException(400, "invalid file path")
        path = project.joinpath(*relative.parts).resolve()
        try:
            path.relative_to(project.resolve())
        except ValueError as exc:
            raise HTTPException(400, "file path escapes project") from exc
        return path

    def session_path(project: Path) -> Path:
        return project / ".code-editor" / "session.json"

    def read_session(project: Path) -> dict:
        path = session_path(project)
        if not path.exists():
            return {"threadId": None, "messages": []}
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise HTTPException(500, "project agent session is corrupt") from exc

    def write_session(project: Path, value: dict) -> None:
        path = session_path(project)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")

    def run_git(project: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(project), *args],
            text=True,
            capture_output=True,
            timeout=30,
        )
        if result.returncode:
            return result.stderr.strip() or result.stdout.strip()
        return result.stdout.strip()

    def git_result(project: Path, *args: str, timeout: int = 30) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", "-C", str(project), *args], text=True, capture_output=True, timeout=timeout
        )

    def git_error(result: subprocess.CompletedProcess, fallback: str) -> str:
        return result.stderr.strip() or result.stdout.strip() or fallback

    def git_status(project: Path) -> dict:
        if not (project / ".git").exists():
            return {"isRepo": False, "files": [], "changedCount": 0}
        status = git_result(project, "status", "--porcelain=v1", "--branch")
        if status.returncode:
            raise HTTPException(500, git_error(status, "could not read Git status"))
        lines = status.stdout.splitlines()
        header = lines[0] if lines and lines[0].startswith("## ") else ""
        branch = header[3:].split("...")[0].split(" ")[0]
        ahead = behind = 0
        match = re.search(r"\[ahead (\d+)(?:, behind (\d+))?\]", header)
        if match:
            ahead, behind = int(match.group(1)), int(match.group(2) or 0)
        else:
            match = re.search(r"\[behind (\d+)\]", header)
            if match:
                behind = int(match.group(1))
        files = []
        for line in lines[1:]:
            if len(line) < 4:
                continue
            files.append({"path": line[3:], "index": line[0], "worktree": line[1]})
        remote = git_result(project, "remote", "get-url", "origin")
        return {
            "isRepo": True,
            "branch": branch,
            "files": files,
            "changedCount": len(files),
            "ahead": ahead,
            "behind": behind,
            "hasRemote": remote.returncode == 0,
            "prAvailable": shutil.which("gh") is not None,
        }

    @api.get("/api/projects")
    async def list_projects():
        root.mkdir(parents=True, exist_ok=True)
        values = []
        for path in sorted(root.iterdir(), key=lambda item: item.name.lower()):
            if not path.is_dir() or path.name in reserved:
                continue
            is_repo = (path / ".git").exists()
            branch = run_git(path, "branch", "--show-current") if is_repo else ""
            values.append({"name": path.name, "isRepo": is_repo, "branch": branch})
        return {"projects": values}

    @api.post("/api/projects")
    async def create_project(request: Request):
        body = await request.json()
        name = str(body.get("name", "")).strip()
        repo_url = str(body.get("repoUrl", "")).strip()
        if not project_name.fullmatch(name) or name in reserved:
            raise HTTPException(400, "project name must use letters, numbers, ., _, or -")
        async with mutation_lock:
            destination = root / name
            if destination.exists():
                raise HTTPException(409, "project already exists")
            root.mkdir(parents=True, exist_ok=True)

            if repo_url:
                if not (
                    repo_url.startswith("https://")
                    or repo_url.startswith("http://")
                    or repo_url.startswith("git@")
                ):
                    raise HTTPException(400, "repository URL must use HTTP(S) or SSH")
                temporary = Path(tempfile.mkdtemp(prefix=f".{name}-", dir=root))
                shutil.rmtree(temporary)
                try:
                    result = await asyncio.to_thread(
                        subprocess.run,
                        ["git", "clone", "--", repo_url, str(temporary)],
                        text=True,
                        capture_output=True,
                        timeout=300,
                    )
                    if result.returncode:
                        raise HTTPException(
                            400, result.stderr.strip() or "repository clone failed"
                        )
                    os.replace(temporary, destination)
                except Exception:
                    shutil.rmtree(temporary, ignore_errors=True)
                    raise
            else:
                destination.mkdir()

            write_session(destination, {"threadId": None, "messages": []})
            await commit()
        return {"name": name, "isRepo": bool(repo_url)}

    @api.patch("/api/projects/{name}")
    async def rename_project(name: str, request: Request):
        project = project_dir(name)
        if (project / ".git").is_file():
            raise HTTPException(400, "linked worktrees cannot be renamed from the editor")
        body = await request.json()
        new_name = str(body.get("name", "")).strip()
        if not project_name.fullmatch(new_name) or new_name in reserved:
            raise HTTPException(400, "project name must use letters, numbers, ., _, or -")
        if new_name == name:
            return {"name": name}
        async with mutation_lock:
            if name in active_turns:
                raise HTTPException(409, "stop the active agent turn before renaming")
            destination = root / new_name
            if destination.exists():
                raise HTTPException(409, "project already exists")
            os.replace(project, destination)
            await commit()
        return {"name": new_name}

    @api.post("/api/projects/{name}/worktrees")
    async def create_worktree(name: str, request: Request):
        project = project_dir(name)
        body = await request.json()
        workspace_name = str(body.get("workspaceName", "")).strip()
        branch = str(body.get("branch", "")).strip()
        start_point = str(body.get("startPoint", "")).strip()
        if not (project / ".git").exists():
            raise HTTPException(400, "this project is not a Git repository")
        if not project_name.fullmatch(workspace_name) or workspace_name in reserved:
            raise HTTPException(400, "worktree name must use letters, numbers, ., _, or -")
        if not branch or branch.startswith("-") or not start_point or start_point.startswith("-"):
            raise HTTPException(400, "branch and starting ref are required")
        destination = root / workspace_name
        async with mutation_lock:
            if destination.exists():
                raise HTTPException(409, "a project or worktree with that name already exists")
            result = await asyncio.to_thread(
                git_result, project, "worktree", "add", "-b", branch, str(destination), start_point,
                timeout=120,
            )
            if result.returncode:
                raise HTTPException(400, git_error(result, "could not create worktree"))
            write_session(destination, {"threadId": None, "messages": []})
            await commit()
        return {"name": workspace_name, "branch": branch, "startPoint": start_point}

    @api.get("/api/projects/{name}/tree")
    async def file_tree(name: str):
        project = project_dir(name)
        entries = []
        ignored = {".git", ".code-editor", "build", ".dart_tool", "node_modules"}
        for base, directories, files in os.walk(project):
            directories[:] = sorted(item for item in directories if item not in ignored)
            relative_base = Path(base).relative_to(project)
            for filename in sorted(files):
                path = relative_base / filename
                entries.append(path.as_posix())
                if len(entries) >= 2000:
                    return {"files": entries, "truncated": True}
        return {"files": entries, "truncated": False}

    @api.get("/api/projects/{name}/file")
    async def read_file(name: str, path: str):
        target = requested_file(project_dir(name), path)
        if not target.is_file():
            raise HTTPException(404, "file not found")
        if target.stat().st_size > max_text_bytes:
            raise HTTPException(413, "file is larger than 2 MiB")
        try:
            content = target.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise HTTPException(415, "file is not UTF-8 text") from exc
        return {"path": path, "content": content}

    @api.put("/api/projects/{name}/file")
    async def write_file(name: str, request: Request):
        project = project_dir(name)
        body = await request.json()
        path = str(body.get("path", ""))
        content = body.get("content")
        if not isinstance(content, str):
            raise HTTPException(400, "content must be text")
        encoded = content.encode("utf-8")
        if len(encoded) > max_text_bytes:
            raise HTTPException(413, "file is larger than 2 MiB")
        async with mutation_lock:
            target = requested_file(project, path)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(encoded)
            await commit()
        return {"saved": True, "path": path, "bytes": len(encoded)}

    @api.get("/api/projects/{name}/git/status")
    async def get_git_status(name: str):
        return git_status(project_dir(name))

    @api.post("/api/projects/{name}/git/commit")
    async def create_commit(name: str, request: Request):
        project = project_dir(name)
        message = str((await request.json()).get("message", "")).strip()
        if not message:
            raise HTTPException(400, "commit message is required")
        if not git_status(project)["isRepo"]:
            raise HTTPException(400, "this project is not a Git repository")
        async with mutation_lock:
            add = await asyncio.to_thread(
                git_result, project, "add", "-A", "--", ".", ":(exclude).code-editor"
            )
            if add.returncode:
                raise HTTPException(400, git_error(add, "could not stage changes"))
            commit_result = await asyncio.to_thread(git_result, project, "commit", "-m", message)
            if commit_result.returncode:
                raise HTTPException(400, git_error(commit_result, "could not create commit"))
            await commit()
        return {"message": commit_result.stdout.strip(), "status": git_status(project)}

    @api.post("/api/projects/{name}/git/push")
    async def push_branch(name: str):
        project = project_dir(name)
        status = git_status(project)
        if not status["isRepo"] or not status["hasRemote"]:
            raise HTTPException(400, "this branch has no origin remote")
        async with mutation_lock:
            result = await asyncio.to_thread(git_result, project, "push")
            if result.returncode:
                raise HTTPException(400, git_error(result, "could not push branch"))
            await commit()
        return {"message": result.stdout.strip() or "Pushed", "status": git_status(project)}

    @api.post("/api/projects/{name}/git/pull-request")
    async def create_pull_request(name: str, request: Request):
        project = project_dir(name)
        body = await request.json()
        title = str(body.get("title", "")).strip()
        base = str(body.get("base", "")).strip()
        description = str(body.get("description", "")).strip()
        auto_merge_method = str(body.get("autoMergeMethod", "")).strip()
        if not title or not base or not description:
            raise HTTPException(400, "pull request title, base branch, and description are required")
        if not shutil.which("gh"):
            raise HTTPException(503, "GitHub CLI is unavailable in this deployment")
        method_flag = {"merge": "--merge", "rebase": "--rebase", "squash": "--squash"}.get(auto_merge_method)
        if auto_merge_method and method_flag is None:
            raise HTTPException(400, "auto-merge method must be merge, rebase, or squash")
        async with mutation_lock:
            result = await asyncio.to_thread(
                subprocess.run,
                ["gh", "pr", "create", "--title", title, "--body", description, "--base", base],
                cwd=str(project), text=True, capture_output=True, timeout=60,
            )
            if result.returncode:
                raise HTTPException(400, git_error(result, "could not create pull request"))
            if method_flag is not None:
                auto_merge = await asyncio.to_thread(
                    subprocess.run,
                    ["gh", "pr", "merge", "--auto", method_flag],
                    cwd=str(project), text=True, capture_output=True, timeout=60,
                )
                if auto_merge.returncode:
                    raise HTTPException(
                        400,
                        "pull request was created, but auto-merge could not be enabled: "
                        + git_error(auto_merge, "unknown error"),
                    )
            await commit()
        return {"url": result.stdout.strip(), "autoMergeEnabled": method_flag is not None, "status": git_status(project)}

    @api.post("/api/projects/{name}/git/pull-request/auto-merge")
    async def enable_auto_merge(name: str, request: Request):
        project = project_dir(name)
        method = str((await request.json()).get("method", "")).strip()
        method_flag = {"merge": "--merge", "rebase": "--rebase", "squash": "--squash"}.get(method)
        if method_flag is None:
            raise HTTPException(400, "merge method must be merge, rebase, or squash")
        status = git_status(project)
        if not status["isRepo"] or not status["hasRemote"]:
            raise HTTPException(400, "this branch has no origin remote")
        if not shutil.which("gh"):
            raise HTTPException(503, "GitHub CLI is unavailable in this deployment")
        async with mutation_lock:
            result = await asyncio.to_thread(
                subprocess.run,
                ["gh", "pr", "merge", "--auto", method_flag],
                cwd=str(project), text=True, capture_output=True, timeout=60,
            )
            if result.returncode:
                raise HTTPException(400, git_error(result, "could not enable auto-merge"))
            await commit()
        return {"message": result.stdout.strip() or "Auto-merge enabled", "status": git_status(project)}

    @api.get("/api/projects/{name}/session")
    async def get_session(name: str):
        return read_session(project_dir(name))

    @api.delete("/api/projects/{name}/session")
    async def reset_session(name: str):
        project = project_dir(name)
        async with mutation_lock:
            write_session(project, {"threadId": None, "messages": []})
            await commit()
        return {"reset": True}

    def stop_terminal_session(session):
        import signal

        process = session["process"]
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        finally:
            try:
                os.close(session["master_fd"])
            except OSError:
                pass

    @api.delete("/api/projects/{name}/terminal/{session_id}")
    async def close_project_terminal(name: str, session_id: int, request: Request):
        if not request.session.get("user"):
            raise HTTPException(401, "authentication required")
        session = terminal_sessions.pop((name, session_id), None)
        if session is not None:
            await asyncio.to_thread(stop_terminal_session, session)
        return {"closed": session is not None}

    @api.websocket("/api/projects/{name}/terminal")
    async def project_terminal(name: str, websocket: WebSocket):
        """Bridge a reconnectable browser terminal to a project shell."""
        if not websocket.session.get("user"):
            await websocket.close(code=4401)
            return
        project = project_dir(name)
        session_id = websocket.query_params.get("session")
        if not session_id or not session_id.isdigit():
            await websocket.close(code=4400)
            return
        session_key = (name, int(session_id))
        await websocket.accept()

        import pty
        import select
        import signal

        session = terminal_sessions.get(session_key)
        if session is None or session["process"].poll() is not None:
            if session is not None:
                await asyncio.to_thread(stop_terminal_session, session)
            master_fd, slave_fd = pty.openpty()
            environment = os.environ.copy()
            environment.update({"TERM": "xterm-256color", "COLORTERM": "truecolor"})
            process = subprocess.Popen(
                ["bash", "-i"],
                cwd=str(project),
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                env=environment,
                start_new_session=True,
            )
            os.close(slave_fd)
            session = {"master_fd": master_fd, "process": process, "output": bytearray()}
            terminal_sessions[session_key] = session
        master_fd = session["master_fd"]
        process = session["process"]

        if session["output"]:
            await websocket.send_bytes(session["output"])

        async def read_terminal() -> None:
            while True:
                ready, _, _ = await asyncio.to_thread(
                    select.select, [master_fd], [], [], 1
                )
                if not ready:
                    if process.poll() is not None:
                        return
                    continue
                try:
                    output = os.read(master_fd, 16 * 1024)
                except OSError:
                    return
                if not output:
                    return
                session["output"].extend(output)
                if len(session["output"]) > 1024 * 1024:
                    del session["output"][: len(session["output"]) - 1024 * 1024]
                await websocket.send_bytes(output)

        output_task = asyncio.create_task(read_terminal())
        try:
            while True:
                message = await websocket.receive_json()
                message_type = message.get("type")
                if message_type == "input" and isinstance(message.get("data"), str):
                    os.write(master_fd, message["data"].encode("utf-8"))
                elif message_type == "resize":
                    columns = int(message.get("cols", 80))
                    rows = int(message.get("rows", 24))
                    if not (1 <= columns <= 500 and 1 <= rows <= 200):
                        continue
                    import fcntl
                    import struct
                    import termios

                    fcntl.ioctl(
                        master_fd,
                        termios.TIOCSWINSZ,
                        struct.pack("HHHH", rows, columns, 0, 0),
                    )
                    os.killpg(process.pid, signal.SIGWINCH)
        except WebSocketDisconnect:
            pass
        finally:
            output_task.cancel()

    @api.get("/api/codex/status")
    async def codex_status():
        try:
            async with AsyncCodex() as codex:
                account = await codex.account()
            return {"authenticated": account.account is not None}
        except Exception as exc:
            return {"authenticated": False, "error": str(exc)}

    @api.get("/api/codex/login")
    async def codex_login():
        async def events():
            try:
                async with AsyncCodex() as codex:
                    login = await codex.login_chatgpt_device_code()
                    yield "data: " + json.dumps(
                        {
                            "stage": "code",
                            "verificationUrl": login.verification_url,
                            "userCode": login.user_code,
                        }
                    ) + "\n\n"
                    result = await login.wait()
                    async with mutation_lock:
                        await commit()
                    yield "data: " + json.dumps(
                        {"stage": "complete", "success": bool(result.success)}
                    ) + "\n\n"
            except Exception as exc:
                yield "data: " + json.dumps(
                    {"stage": "error", "error": str(exc)}
                ) + "\n\n"

        return StreamingResponse(
            events(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    def agent_activity(event) -> dict | None:
        """Turn an SDK notification into a small, user-facing progress update."""
        if event.method != "item/started":
            return None
        item = getattr(event.payload.item, "root", event.payload.item)
        item_type = getattr(item, "type", "")
        if item_type == "commandExecution":
            command = " ".join(getattr(item, "command", "").split())
            return {"type": "activity", "text": f"Running: {command}"}
        if item_type == "fileChange":
            paths = [change.path for change in getattr(item, "changes", [])]
            description = ", ".join(paths[:3])
            if len(paths) > 3:
                description += ", …"
            return {
                "type": "activity",
                "text": f"Editing {description}" if description else "Editing files",
            }
        if item_type == "reasoning":
            return {"type": "activity", "text": "Planning the next step"}
        if item_type == "agentMessage":
            return {"type": "activity", "text": "Preparing a response"}
        return None

    async def execute_agent_run(name: str, project: Path, prompt: str, run: dict):
        """Run Codex and make its non-sensitive progress available to the chat UI."""
        queue = run["events"]

        def emit(value: dict) -> None:
            queue.put_nowait(value)

        response_parts = []
        completed_response = ""
        try:
            emit({"type": "activity", "text": "Starting Codex"})
            async with AsyncCodex() as codex:
                account = await codex.account()
                if account.account is None:
                    raise RuntimeError("connect Codex before running an agent")
                if run["stopped"]:
                    raise RuntimeError("agent turn was stopped")

                async with mutation_lock:
                    session = read_session(project)
                if session.get("threadId"):
                    thread = await codex.thread_resume(
                        session["threadId"],
                        cwd=str(project),
                        sandbox=Sandbox.workspace_write,
                        approval_mode=ApprovalMode.auto_review,
                    )
                else:
                    thread = await codex.thread_start(
                        cwd=str(project),
                        sandbox=Sandbox.workspace_write,
                        approval_mode=ApprovalMode.auto_review,
                        developer_instructions=(
                            "Work only inside the current project. Inspect the repository before "
                            "editing, make requested changes directly, run proportionate checks, "
                            "and finish with a concise summary of edits and verification."
                        ),
                    )

                turn = await thread.turn(prompt)
                run["turn"] = turn
                if run["stopped"]:
                    await turn.interrupt()
                async for event in turn.stream():
                    activity = agent_activity(event)
                    if activity is not None:
                        emit(activity)
                    if event.method == "item/agentMessage/delta":
                        response_parts.append(event.payload.delta)
                        emit({"type": "response_delta", "text": event.payload.delta})
                    elif event.method == "item/completed":
                        item = getattr(event.payload.item, "root", event.payload.item)
                        if getattr(item, "type", "") == "agentMessage" and getattr(
                            getattr(item, "phase", None), "value", None
                        ) == "final_answer":
                            completed_response = item.text

                response_text = completed_response or "".join(response_parts)
                async with mutation_lock:
                    messages = list(session.get("messages", []))
                    messages.extend(
                        [
                            {"role": "user", "text": prompt},
                            {"role": "assistant", "text": response_text},
                        ]
                    )
                    persisted = {"threadId": thread.id, "messages": messages[-100:]}
                    write_session(project, persisted)
                    await commit()
                emit({"type": "complete", "messages": persisted["messages"]})
        except Exception as exc:
            if run["stopped"]:
                emit({"type": "complete", "messages": None, "response": "Stopped."})
            else:
                emit({"type": "error", "error": str(exc)})
        finally:
            run["complete"] = True
            queue.put_nowait(None)
            if active_turns.get(name) is run:
                active_turns.pop(name, None)

    @api.post("/api/projects/{name}/agent")
    async def run_agent(name: str, request: Request):
        project = project_dir(name)
        body = await request.json()
        prompt = str(body.get("prompt", "")).strip()
        if not prompt:
            raise HTTPException(400, "prompt is required")
        async with mutation_lock:
            if name in active_turns:
                raise HTTPException(409, "an agent turn is already running")
            run_id = os.urandom(16).hex()
            run = {"events": asyncio.Queue(), "stopped": False, "complete": False}
            active_turns[name] = run
            agent_runs[run_id] = run
            run["task"] = asyncio.create_task(execute_agent_run(name, project, prompt, run))
        return {"runId": run_id}

    @api.get("/api/projects/{name}/agent/events/{run_id}")
    async def agent_events(name: str, run_id: str):
        project_dir(name)
        run = agent_runs.get(run_id)
        if run is None:
            raise HTTPException(404, "agent run not found")

        async def events():
            try:
                while True:
                    event = await run["events"].get()
                    if event is None:
                        break
                    yield "data: " + json.dumps(event) + "\n\n"
            finally:
                if run["complete"]:
                    agent_runs.pop(run_id, None)

        return StreamingResponse(
            events(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    @api.post("/api/projects/{name}/agent/stop")
    async def stop_agent(name: str):
        project_dir(name)
        active_turn = active_turns.get(name)
        if active_turn is None:
            raise HTTPException(409, "no agent turn is running")
        active_turn["stopped"] = True
        if active_turn.get("turn") is not None:
            await active_turn["turn"].interrupt()
        return {"stopped": True}

    api.mount("/", StaticFiles(directory="/app/build/web", html=True), name="web")
    return api

