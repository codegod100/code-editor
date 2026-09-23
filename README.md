# Codex Workspace

A repository-based web workspace for editing files and directing a Codex agent.
The Flutter UI and FastAPI backend deploy together as one Modal application.

## What it does

- Creates durable project folders or clones Git repositories.
- Browses and edits UTF-8 project files in the browser.
- Starts and resumes one Codex SDK thread per project.
- Lets Codex inspect, edit, and verify the selected project with
  `workspace-write` sandbox access.
- Requires Pocket ID OIDC authentication before serving the UI or any API.
- Authenticates Codex with ChatGPT device login; no API key is embedded in the
  app or frontend.

## Storage

All mutable state is on the Modal v2 Volume
`cloud-code-editor-projects`, mounted at the absolute path `/projects`:

- `/projects/<project>` contains the folder or Git checkout.
- `/projects/<project>/.code-editor/session.json` contains the project's Codex
  thread id and visible conversation history.
- `/projects/.codex` is `CODEX_HOME` and contains the server-side Codex login
  and runtime state.

Every clone, editor save, session reset, login, and completed agent turn calls
`Volume.commit()` explicitly. The web function is limited to one container so
two containers cannot concurrently modify the same Volume files.

The app image is stateless. Rebuilding or restarting it does not remove project
data. To make an offline backup:

```sh
modal volume get cloud-code-editor-projects / ./cloud-code-editor-projects-backup
```

Restore individual files or folders with `modal volume put`. Treat that backup
as sensitive because it includes repository contents and Codex authentication
state.

## Deploy

Create a confidential Pocket ID OIDC client with PKCE enabled and this exact
callback URL:

```text
https://codegod100--cloud-code-editor-serve.modal.run/auth/callback
```

Store its credentials in a Modal Secret named `code-editor-pocket-id` together
with an independent random cookie-signing secret:

```sh
modal secret create code-editor-pocket-id \
  OIDC_CLIENT_ID='<pocket-id-client-id>' \
  OIDC_CLIENT_SECRET='<pocket-id-client-secret>' \
  SESSION_SECRET='<random-value-at-least-32-bytes>'
```

The deployment intentionally fails if that secret or any required key is
missing; there is no anonymous mode.

```sh
modal deploy modal_app.py
```

The first image build installs Flutter, FastAPI, Git, and the pinned Codex
Python SDK, then compiles the Flutter release bundle. Later builds reuse Modal's
image layers.

After signing in through Pocket ID:

1. Select **Project** to create a folder or clone an HTTP(S)/SSH repository.
2. Select **Connect Codex**, open the verification page, and enter the shown
   device code.
3. Open files in the explorer or ask the agent to work on the current project.

Repository credentials are not accepted by the UI. Private clones require Git
credentials to be configured explicitly in the runtime image or through a
dedicated secret before use.

## Local Flutter development

The web UI expects the same-origin `/api` routes supplied by `modal_app.py`.
For UI-only work, install Flutter and run:

```sh
flutter pub get
flutter run -d chrome
```

The desktop-only prototype remains in `lib/main_desktop.dart`; the deployed web
entry point is `lib/main.dart`.
