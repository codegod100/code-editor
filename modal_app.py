"""Repository-backed Codex workspace deployed on Modal.

Deploy with `modal deploy modal_app.py`. Project data and Codex authentication
live on the durable `cloud-code-editor-projects` Volume mounted at /projects.
"""

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
    .apt_install("git")
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

    from fastapi import FastAPI, HTTPException, Request
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

    @api.post("/api/projects/{name}/agent")
    async def run_agent(name: str, request: Request):
        project = project_dir(name)
        body = await request.json()
        prompt = str(body.get("prompt", "")).strip()
        if not prompt:
            raise HTTPException(400, "prompt is required")
        async with mutation_lock:
            session = read_session(project)

            async with AsyncCodex() as codex:
                account = await codex.account()
                if account.account is None:
                    raise HTTPException(401, "connect Codex before running an agent")

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
                active_turn = {"turn": turn, "stopped": False}
                active_turns[name] = active_turn
                try:
                    result = await turn.run()
                    response_text = result.final_response or ""
                except Exception as exc:
                    if active_turn["stopped"]:
                        response_text = "Stopped."
                    else:
                        raise HTTPException(500, f"Codex turn failed: {exc}") from exc
                finally:
                    if active_turns.get(name) is active_turn:
                        active_turns.pop(name)

            messages = list(session.get("messages", []))
            messages.extend(
                [
                    {"role": "user", "text": prompt},
                    {"role": "assistant", "text": response_text},
                ]
            )
            session = {"threadId": thread.id, "messages": messages[-100:]}
            write_session(project, session)
            await commit()
        return {
            "threadId": thread.id,
            "response": response_text,
            "messages": session["messages"],
        }

    @api.post("/api/projects/{name}/agent/stop")
    async def stop_agent(name: str):
        project_dir(name)
        active_turn = active_turns.get(name)
        if active_turn is None:
            raise HTTPException(409, "no agent turn is running")
        active_turn["stopped"] = True
        await active_turn["turn"].interrupt()
        return {"stopped": True}

    api.mount("/", StaticFiles(directory="/app/build/web", html=True), name="web")
    return api
