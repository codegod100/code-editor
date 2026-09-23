# Codex Workspace

A repository-based web workspace for editing files and directing a Codex agent.
The Flutter UI and FastAPI backend deploy together as one Modal application.

## What it does

- Creates durable project folders or clones Git repositories.
- Browses and edits UTF-8 project files in the browser.
- Starts and resumes one Codex SDK thread per project.
- Lets Codex inspect, edit, and verify the selected project with
  `workspace-write` sandbox access.
- Provides an authenticated, project-rooted browser terminal rendered by
  `libghostty-vt` WebAssembly.
- Requires AT Protocol OAuth authentication before serving the UI or any API.
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
- `/projects/.freeq-bots` holds the did:key identity and delegation certificate
  used by the FreeQ handoff sender. It is mounted on the same durable Volume,
  so its identity survives restarts.

Every clone, editor save, session reset, login, and completed agent turn calls
`Volume.commit()` explicitly. The web function is limited to one container so
two containers cannot concurrently modify the same Volume files.

Terminal shells remain live while the user returns from the terminal workspace
to the editor: reopening the workspace reconnects to each tab's Bash process
and restores up to 1 MiB of its recent output. Closing a terminal tab ends its
shell. Terminal sessions and scrollback are in-memory only, so a container
restart does not preserve them.

The app image is stateless. Rebuilding or restarting it does not remove project
data. To make an offline backup:

```sh
modal volume get cloud-code-editor-projects / ./cloud-code-editor-projects-backup
```

Restore individual files or folders with `modal volume put`. Treat that backup
as sensitive because it includes repository contents and Codex authentication
state.

## Deploy

Generate an ES256 private JWK for the confidential AT Protocol OAuth client,
then store it with an independent cookie-signing secret:

```text
https://codegod100--cloud-code-editor-serve.modal.run/auth/callback
```

Store it in a Modal Secret named `code-editor-atproto-oauth` together with an
independent random cookie-signing secret:

```sh
modal secret create code-editor-atproto-oauth \
  ATPROTO_OAUTH_PRIVATE_JWK='<ES256-private-JWK>' \
  SESSION_SECRET='<random-value-at-least-32-bytes>'
```

The deployment intentionally fails if that secret or any required key is
missing; there is no anonymous mode.

## FreeQ bot handoff

The Agent panel's FreeQ button discovers published bot manifests from the
canonical server, then sends a signed, open `handoff/offer` into the configured
channel. Any capable bot there may claim it. Its `accept`, `complete`, `fail`,
or `decline` act is read from the channel audit trail; a completion resumes the
project's existing Codex thread, which inspects and incorporates the result.

The editor uses the DID returned by the current AT Protocol OAuth session as
the FreeQ sender owner. Its nick is the signed-in handle plus `-editor`, with
characters not accepted by IRC normalized to `-` (for example,
`nandi.uk` becomes `nandi-uk-editor`). It stores the bot key and delegation
certificate under `/projects/.freeq-bots/<short-id>`, so no shared FreeQ DID
or nick secret is needed.

The sender is an ephemeral canonical `@freeq/bot-kit` session: it joins the
chosen channel, emits `actTags('handoff', 'offer', ...)` with `caps`, `title`,
and `ctx`, then remains connected until the offer reaches `complete`, `fail`,
`decline`, or its deadline. It then exits cleanly. A bot must be present in
that channel and claim the selected capability.

```sh
python3 deploy.py
```

The first image build installs Flutter, FastAPI, Git, and the pinned Codex
Python SDK, then compiles the Flutter release bundle. Later builds reuse Modal's
image layers.

After signing in with an AT Protocol handle or DID:

1. Select **Project** to create a folder or clone an HTTP(S)/SSH repository.
2. Select **Connect Codex**, open the verification page, and enter the shown
   device code.
3. Open files in the explorer or ask the agent to work on the current project.

Repository credentials are not accepted by the UI. Private clones require Git
credentials to be configured explicitly in the runtime image or through a
dedicated secret before use.

## Local Flutter development

The web UI expects the same-origin `/api` routes supplied by `deploy.py`.
For UI-only work, install Flutter and run:

```sh
flutter pub get
dart analyze
flutter run -d chrome
```

The desktop-only prototype remains in `lib/main_desktop.dart`; the deployed web
entry point is `lib/main.dart`.
