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
`cloud-code-editor-projects`, mounted at the absolute path `/workspace`:

- `/workspace/<project>` contains the folder or Git checkout.
- `/workspace/<project>/.code-editor/session.json` contains the project's Codex
  thread id and visible conversation history.
- `/workspace/.codex` is `CODEX_HOME` and contains the server-side Codex login
  and runtime state.
- `/workspace/.freeq-bots` holds the did:key identity and delegation certificate
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

This is a public AT Protocol OAuth client using PKCE and DPoP. Store an
independent random cookie-signing secret for the application's browser session:

```text
https://codegod100--cloud-code-editor-serve.modal.run/auth/callback
```

Store it in a Modal Secret named `code-editor-session`:

```sh
modal secret create code-editor-session \
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
certificate under `/workspace/.freeq-bots/<short-id>`, so no shared FreeQ DID
or nick secret is needed.

The sender is an ephemeral canonical `@freeq/bot-kit` session: it joins the
chosen channel, emits `actTags('handoff', 'offer', ...)` with `caps`, `title`,
and `ctx`, then remains connected until the offer reaches `complete`, `fail`,
`decline`, or its deadline. It then exits cleanly. A bot must be present in
that channel and claim the selected capability.

### Fly worker

The long-lived Fly worker that claims editor offers lives in
[services/freeq-bot](services/freeq-bot). Its deployed contract is explicit:
freeq-bot stays connected to #tasks and only claims prime_agent offers. The
current Fly machine mounts its durable state volume at /data, which holds its
did:key identity; do not remove or replace that volume during deployments.

The paired Modal task-runner template lives in
[services/prime-agent](services/prime-agent). Use it as the starting point for
new workers: it keeps paid model credentials and Sandbox lifecycle controls in
Modal, while the Fly worker only dispatches prompts. Its default model is GLM
5.3 Flash, with GLM 4.7 Flash used only when Workers AI returns a capacity 429.

Deploy the worker from that directory so Fly uses its Dockerfile and config:

~~~sh
cd services/freeq-bot
fly deploy
~~~

The editor now recognizes the worker's canonical claim event in addition to the
legacy accept event. A handoff using another capability, such as call_tool, is
intentionally left unclaimed by this worker.

```sh
python3 deploy.py
```

### Continuous deployment

Pushes to `main` run `.github/workflows/deploy-cloud-code-editor.yml`, which
deploys the merge commit to Modal using a digest-pinned `code-editor-ci` image
in GitHub Container Registry. The image contains Python 3.12, Git, and the
pinned Modal CLI; it is rebuilt only when `.github/ci/Dockerfile` or its
publishing workflow changes (or when **Publish CI Base Image** is run manually).

Run **Publish CI Base Image** once before the first deployment. Set its
`digest` job output as the GitHub Actions repository variable
`CODE_EDITOR_CI_IMAGE_DIGEST` (for example, `sha256:...`). The deploy workflow
validates that required value before starting a container, and uses the exact
published digest rather than the mutable `v1` tag. After a deliberate CI image
update, replace that variable with the newly published digest to adopt it.

Pull requests are auto-merged by **Enable Pull Request Auto-Merge**. Configure
the required repository secret `AUTO_MERGE_TOKEN` with a GitHub App installation
token or fine-grained personal access token that can merge pull requests in this
repository. Do not use `GITHUB_TOKEN`: GitHub intentionally suppresses
downstream workflow runs for pushes it creates, so a merge made with that token
will not start the deployment workflow.

Use the included script to create or update the variable. It obtains the token
from the authenticated GitHub CLI account, which must be allowed to manage
Actions variables. From this repository checkout, it identifies the repository,
resolves the immutable digest currently assigned to the `v1` CI-image tag, and
stores that digest:

```sh
python3 scripts/set_ci_image_digest.py
```

The script requires the full digest (64 lowercase hexadecimal characters),
does not print the token, and tells you to run `gh auth login -h github.com`
when no valid GitHub CLI authentication is available. If the existing GitHub
CLI token cannot read package versions, it runs `gh auth refresh` and asks you
to approve the required `read:packages` permission before retrying.

For non-interactive use, supply both values explicitly:

```sh
python3 scripts/set_ci_image_digest.py \
  --repo codegod100/code-editor \
  --digest sha256:...
```

Configure a Modal service user with
Contributor access to the deployment environment, then run this script. It
securely prompts for both credentials, so they are not placed in shell history:

```sh
python3 scripts/configure_modal_github_secrets.py
```

The setup script requires an authenticated GitHub CLI session with permission
to manage repository Actions secrets. It sets `MODAL_TOKEN_ID` and
`MODAL_TOKEN_SECRET` only; the values are passed to `gh` on standard input and
are never printed.

### CI failure repair webhook

The deployed service can turn an eligible failed GitHub Actions run into a
Codex-authored **draft** pull request. It receives only signed `workflow_run`
events and accepts failures only from an explicit repository allowlist. It
ignores pull-request runs and branches beginning `codex/`, preventing repair
PRs from recursively triggering more repairs. A durable ledger at
`/workspace/.system/ci-repairs.json` deduplicates each repository/run pair
across restarts; repair checkouts themselves are temporary and removed when a
run finishes.

Before deployment, configure the required Modal Secret and GitHub webhook.
By default, the setup script uses the current authenticated `gh` token and
generates a high-entropy webhook secret itself; neither value is printed. The
token needs Actions read access and Contents/Pull requests read-write access
on each configured repository. It replaces the Modal secret and creates or
updates the webhook using the authenticated GitHub CLI account:

```sh
python3 scripts/configure_ci_repair_webhook.py
```

Pass `--repo owner/repository` more than once to enable multiple repositories,
and `--environment main` when the deployment uses a named Modal environment.
For a least-privilege dedicated bot token, pass `--prompt-github-token` instead.
The service fetches the failed log, checks out the precise failed SHA, asks
Codex for the smallest verified repair, and creates a draft PR only when Codex
leaves a real change to commit. It never auto-merges the result.

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
