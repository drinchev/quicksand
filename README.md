# quicksand — run Claude Code and shell sessions in sandboxed macOS user accounts

quicksand (`qs`) manages named, fully isolated macOS user accounts to sandbox
AI agents and shell commands — a lightweight alternative to virtual machines,
built from plain Unix primitives: user accounts, group ACLs, `sudo`, and
`sandbox-exec`.

> **Credit where it's due:** quicksand is heavily based on the ideas and
> architecture of [SandVault](https://github.com/webcoyote/sandvault) by
> **[Patrick Wyatt](https://github.com/webcoyote)**. The core design — a
> dedicated sandbox user per workspace, passwordless `sudo` switching, a
> shared workspace with inherited ACLs, defense-in-depth via `sandbox-exec`,
> and clean uninstall — is his. quicksand is a smaller, personal
> reimplementation of those ideas focused on per-repository sandboxes with
> GitHub deploy keys. If you want the fuller-featured original (multiple AI
> agents, browser and iOS Simulator automation, SSH mode), use SandVault.

- **Claude Code ready** — installed inside the sandbox on first run, launched
  with `--dangerously-skip-permissions` (the sandbox is the permission system)
- **Per-repo isolation** — `qs clone` gives each sandbox its own repo copy
  and a scoped GitHub deploy key; no host credentials enter the sandbox
- **Shared agent memory** — a per-sandbox `notes/` knowledge base in the
  shared workspace, indexed by [qmd](https://github.com/tobi/qmd) alongside
  Claude Code's auto-memory, so agent sessions keep context across runs
  (shared host ↔ sandbox, never across sandboxes)
- **Cross-sandbox memory (opt-in)** — `qs memory` attaches a private GitHub
  "memory repo" cloned per sandbox with its own deploy key; agents share
  knowledge by opening PRs you merge, with commits authored per sandbox —
  nothing propagates between sandboxes without your review
- **Fast** — no VM overhead; entering a sandbox is a `sudo` away
- **Passwordless** — switch accounts without a prompt (after setup)
- **Self-healing** — sandboxes rebuild automatically when the configuration
  changes (content-fingerprinted builds)
- **Defense in depth** — limited user account *plus* `sandbox-exec` profile
- **Clean uninstall** — removes the user, group, sudoers entry, rendered
  profile, GitHub deploy keys, and host-side git remotes

## Security model

A sandbox session has limited access to your machine:

```
- writable:  /Users/qs-NAME                  -- the sandbox user's home
- writable:  /Users/Shared/qs-NAME           -- shared workspace (you + sandbox)
- writable:  /tmp, per-user /var/folders     -- scratch space
- readable:  /usr, /bin, /etc, /opt, ...     -- system directories
- no access: /Users/*                        -- all other home directories
- no access: /Volumes/*                      -- removable/network drives
                                                (boot volume stays readable)
- no access: /Library/Keychains              -- system keychain
```

Beyond `sandbox-exec`, the sandbox user is stripped from the `staff` group,
so files that are merely group-readable on a stock macOS install stay out of
reach. Network access is unrestricted — the sandbox is an isolation boundary
for your *files*, not an egress filter.

## Installation

`qs` ships inside [Quicksand.app](#quicksandapp), together with the scripts it
runs, so the app is the whole install:

```bash
git clone https://github.com/drinchev/quicksand && cd quicksand
app/scripts/bundle.sh && cp -R app/build/Quicksand.app ~/Applications/
open ~/Applications/Quicksand.app    # then "Install qs command" in its menu
```

"Install qs command" links `/usr/local/bin/qs` to
`Quicksand.app/Contents/MacOS/qs` (macOS asks for an admin password). To do it
by hand: `sudo ln -sfn ~/Applications/Quicksand.app/Contents/MacOS/qs /usr/local/bin/qs`.

`qs` is moving from bash to Swift one command at a time. Today the Swift `qs`
hands every command to the bash script, `qs.bash`, unchanged; you can still
run `/path/to/quicksand/qs.bash` directly (e.g. from a checkout while
developing). Earlier installs that put the checkout on `PATH` or aliased
`/path/to/quicksand/qs` need to switch to one of the two.

Requires macOS and admin rights (builds use `sudo` to create the sandbox
user). `gh` is optional but recommended for automatic deploy-key handling.

## Quick start

```bash
# Create a sandbox and clone a repo into it (registers a deploy key)
qs clone work https://github.com/you/project

# Run Claude Code in the repo
qs claude work project

# Or a plain shell
qs shell work project

# See what exists
qs list

# Tear it all down (removes the deploy key and git remotes too)
qs uninstall work
```

The first command for a given NAME builds the sandbox automatically: a
hidden `qs-NAME` user and group, a home directory, a shared workspace at
`/Users/Shared/qs-NAME`, a sudoers entry, and a rendered `sandbox-exec`
profile.

## Commands

```
qs build     NAME [-r]                   build (or repair) a sandbox
qs shell     NAME [PATH] [-- args ...]   zsh session in the sandbox
qs claude    NAME [PATH] [-- args ...]   Claude Code in the sandbox
qs clone     NAME URL_OR_PATH            clone a repo into the sandbox
qs gh-auth   NAME [OWNER/REPO]           set up a repo-scoped gh token
qs gcp-auth  NAME TARGET_PROJECT         provision a scoped GCP service account
qs gcp-token NAME                        refresh the GCP access token (~1h)
qs op-auth   NAME [--write]              provision a 1Password vault for secrets
qs docker    NAME [off]                  let the sandbox run containers via a broker
qs ssh-auth  NAME [KEY.pub | off]        allow SSH into the sandbox (sandboxed sessions)
qs uninstall NAME                        remove the sandbox completely
qs list                                  list sandboxes, their clones and memory repo

Short aliases: b, s, cl, c, g, gp, gt, o, d, sa, u, l.
```

PATH is where the session starts, *inside* the sandbox: relative paths and
`~/...` resolve against the sandbox home, so `qs claude work project` starts
in `~/project` — where `qs clone` links each repository. Absolute paths are
used as-is; omitted, the session starts in the sandbox home.

Options:

```
-r, --rebuild        rebuild configuration, permissions, and ACLs
-n, --no-build       refuse to make changes; error if a build is needed
-x, --no-sandbox     disable sandbox-exec (still switches users)
-v, --verbose        more output (-vv, -vvv for even more)
```

Arguments after `--` are passed to the spawned shell or to `claude`:

```bash
qs claude work project -- -p "run the tests and fix failures"
echo "pwd; exit" | qs shell work
```

Set `QUICKSAND_ARGS` for default arguments, prepended to every command line
(shell quoting works: `export QUICKSAND_ARGS='-v'`).

## Cloning and deploy keys

`qs clone NAME URL_OR_PATH` clones into the shared workspace and symlinks
the repo at `~/<repo>` inside the sandbox:

- **GitHub URLs** (HTTPS is auto-converted to SSH): a per-repo `ed25519`
  deploy key is generated inside the workspace and registered via `gh` with
  write access, titled `qs:NAME:repo`. The sandbox pushes and pulls with that
  key alone — your host SSH keys and `gh` auth never enter the sandbox.
- **Local paths**: the clone uses the repo's `origin` URL, and the host repo
  gains a `quicksand` remote pointing at the sandbox copy, so you can
  `git fetch quicksand` to review work done inside.

Every clone is recorded in a host-side manifest; `qs uninstall` uses it to
delete the deploy key from GitHub and remove the `quicksand` remote again.

## GitHub API access (`gh`)

The deploy key handles git transport, but not the GitHub *API* — opening PRs,
writing PR comments, reading commits, branches and CI runs. For that the
sandbox needs a token, and `qs gh-auth` sets one up scoped to a single repo
(not your whole account), using a **fine-grained personal access token**:

```bash
qs gh-auth work you/project     # or omit the repo if the sandbox has one clone
```

`qs clone` offers this automatically after registering the deploy key. The
flow is a guided manual one, because fine-grained PATs can't be minted via
API:

1. `qs` prints a GitHub token-creation link with the name, resource owner,
   90-day expiry and permissions **prefilled**. GitHub can't preselect the
   repository itself, so you pick it from the "Only select repositories"
   dropdown and confirm the owner before generating.
2. You paste the token back (input hidden); `qs` validates it against the
   repo and saves it to the workspace.
3. On the next session, `gh` signs in automatically inside the sandbox.

Permissions requested are least-privilege: `Pull requests: write` (PRs + PR
comments), `Actions: write` (re-run CI workflows), plus read-only `Contents`
(commits/branches), `Checks`, `Commit statuses` (CI) and `Variables` (Actions
variables). The token is API-only — `git push`/`pull` stay on the deploy key,
so it never needs write access to repository contents.

Fine-grained PATs have **no revoke API**, so `qs uninstall` can't delete one
for you; it prints a reminder with the [token settings
link](https://github.com/settings/tokens?type=beta). The short expiry is the
real backstop — re-run `qs gh-auth` to refresh.

## Google Cloud access (`gcloud` / `gsutil`)

The Cloud SDK is installed in every sandbox (`48-install-gcloud.sh`), but it
needs credentials to do anything. `qs gcp-auth` provisions a **per-sandbox
service account** scoped to one or more projects — your host gcloud identity
never enters the sandbox, mirroring the deploy-key/PAT split for GitHub:

```bash
qs gcp-auth work metadata-dev-4d18
# or span several projects (e.g. the sandbox's project + a shared registry):
qs gcp-auth work metadata-dev-4d18 shared-packages-fad1
```

The arguments are the **target projects** to grant read access on — pass more
than one when the resources you need live in different projects (a common case:
an Artifact Registry / npm repo hosted in a separate shared-packages project).
The service account's own **owner project** (where it's created) is prompted,
defaulting to your active gcloud project — press Enter to accept. The flow then:

1. Creates the service account `qs-NAME` in the owner project (display name
   `Quicksand sandbox: NAME`). The sandbox name is lowercased and `_`→`-` to
   satisfy GCP's account-id rules; idempotent if it already exists.
2. Grants `roles/viewer` and `roles/artifactregistry.reader` on **each** target
   project (override with `QS_GCP_ROLES="role1,role2"`).
3. Grants your host's active identity `roles/iam.serviceAccountTokenCreator`
   on the SA, then mints a short-lived access token by impersonating it and
   writes the token to the workspace (`chmod 600`).
4. Pins the **first** target project as the sandbox's default.

On the next session, `61-gcp-auth.sh` points gcloud at the token file
(`gcloud config set auth/access_token_file`, which `gsutil` and `gcloud
storage` honor) and sets the default project — so `gsutil ls`, `gcloud
storage`, and `bq` just work.

**No downloadable keys.** Most GCP orgs enforce
`constraints/iam.disableServiceAccountKeyCreation`, which blocks SA key files
outright. quicksand sidesteps that entirely by using **impersonated tokens**
instead of keys. The trade-off is lifetime: impersonated tokens last about an
hour (and 1h is a hard cap unless an org admin allows lifetime extension).

quicksand handles the expiry for you in two ways:

- **On launch:** every `qs shell`/`qs claude` mints a fresh token on the host
  before entering (skipped if the current one is under ~50 min old, and
  best-effort — a failed mint never blocks entry). So any session under an hour
  needs nothing manual.
- **Mid-session:** for a session that outlives its token, refresh from another
  host terminal — the sandbox re-reads the token file on every gcloud call, so
  it picks up the new one live, no re-entry:
  ```bash
  qs gcp-token work
  ```

Your host must be logged in (`gcloud auth login`) with permission to create
service accounts in the owner project, set IAM policy on each target project,
and set IAM policy on the SA itself (to grant token-creator). `qs uninstall`
removes the IAM bindings and deletes the service account (which drops the
token-creator binding with it).

## App secrets via 1Password (`op`)

Deploy keys, the `gh` token and the GCP token cover *infrastructure* access, but
not the arbitrary **app secrets** a project needs at runtime — database
passwords, third-party API keys, and so on. `qs op-auth` provisions those
through 1Password so they're fetched on demand and **never written to the
sandbox disk**:

```bash
qs op-auth work            # read-only vault
qs op-auth work --write    # also let the sandbox store secrets back
```

Using your own host 1Password (which must be signed in — `op signin`, or the
desktop app with CLI integration enabled), it:

1. Creates a vault `qs-NAME` if absent.
2. Creates a **service account** scoped to *only that vault* — `read_items` by
   default, `write_items` too with `--write` — with a 90-day expiry.
3. Stores the service-account token (shown once) back in that vault.

The service account is the sandbox's identity: it carries no biometric and no
desktop-app dependency, so it works inside the isolated user account where the
1Password app and host keychain are unreachable. The token is scoped to one
vault and is independently **revocable and expiring**.

On every launch, the host reads the token from your 1Password into a transient
`_quicksand/op-token` (`0600`), which `62-op-auth.sh` exports as
`OP_SERVICE_ACCOUNT_TOKEN`; `15-op-token.sh` removes it again when the last
session of the sandbox exits. So the token is sourced fresh from 1Password each
session and **never persists in the sandbox between sessions**. Sessions that
don't start from `qs` get it the same way, through the
[credential broker](#credentials-on-demand-qs-auth-refresh). Inside the sandbox:

```bash
op read "op://qs-NAME/<item>/<field>"     # one field to stdout
op run  --env-file=<file> -- <command>    # inject op:// refs into a subprocess
```

You add and edit the secrets yourself from the host (your own 1Password identity
has full access to the vault) — the sandbox's read-only token can't, which is
why adding secrets never needs `--write`. Reading the token at launch may prompt
1Password to unlock, mirroring how `gcp-auth` relies on host `gcloud`.

1Password has **no CLI to revoke** a service account (only the web UI), so
`qs uninstall` best-effort deletes the stored token item, prints a revoke
reminder, and **leaves the vault and its secrets intact** — your data is never
deleted.

## Docker via a host-side broker (`qs docker`)

There is no Docker engine inside a sandbox, and handing one the host's Docker
socket would undo the whole isolation model: whoever controls the socket can
`docker run -v /Users/you:/host ...` and read or write everything your engine's
file sharing reaches — the socket is host-user-equivalent. OrbStack and Docker
Desktop (outside the Business tier) have no daemon-side policy mechanism to
prevent that.

`qs docker NAME` takes a different route: a **command-level broker**. The
sandbox never sees a Docker API; instead a `qs-docker` client sends a small
JSON request (verb plus a few values) over a Unix socket in `_quicksand/`,
and a host-side broker composes every `docker` invocation itself from a fixed
hardened template — the client cannot supply a single flag. That keeps the
security-critical surface ~150 auditable lines instead of a Docker-API
payload filter, where one missed field (`Binds` vs `Mounts`, `docker cp`,
volume remounts, image `load`) is a host compromise.

```bash
qs docker work        # enable — needs docker + jq on the host
qs docker work off    # disable again
```

Inside the sandbox:

```bash
qs-docker run -w ~/project node:20 node -e 'console.log("hi")'
qs-docker build -t qs-work/app ~/project
qs-docker pull postgres:16
qs-docker ps                # only this sandbox's containers
qs-docker logs <id>
qs-docker stop <id>
```

The policy, enforced entirely host-side:

- **Mounts**: the shared workspace, nothing else — hard-coded, with
  workdir/build paths `realpath`-checked against symlink and `..` escapes.
  `_quicksand/` (live credentials, the broker's own socket) is masked out
  of the container by an empty anonymous volume, and may not be (part of)
  a build context — so third-party images never see the sandbox's tokens.
- **Hardening**: `--cap-drop ALL`, `--security-opt no-new-privileges`,
  4 GB / 4 CPUs / 512 pids.
- **Ownership**: everything is labeled `quicksand.sandbox=NAME`; `ps`,
  `logs` and `stop` are scoped to that label, build tags are forced under
  `qs-NAME/` so a sandbox can't clobber host images, and `qs uninstall`
  reaps the labeled containers and images.
- **Surface**: six verbs, no `exec`, no `cp`, no volumes, no TTY.
- **Trust boundary**: what the broker cannot policy away is the engine
  itself. A container-escape vulnerability lands in the engine's Linux VM,
  with whatever macOS file sharing that VM has — enabling `qs docker` adds
  the container engine to the sandbox's trusted computing base, so keep it
  updated. Build-time resource use (CPU, disk) is also uncapped; a hostile
  build can waste resources, not read files.

The broker script is staged under `~/.config/quicksand/`, and
[Quicksand.app](#quicksandapp) runs it: the app owns the socket
(`/Users/Shared/quicksand/docker.sock`) and starts one short-lived broker per
connection, so nothing runs while idle — and the code executing as your user
lives host-side where the sandbox can't edit it. The `docker`/`jq` binary
paths are pinned into the broker's spec
(`~/.config/quicksand/brokers/com.quicksand.docker-broker.NAME.plist`) at
install time. Containers themselves are confined by your
engine's VM, not by `sandbox-exec`; container network egress is unrestricted,
matching quicksand's "files, not egress" model.

## SSH into a sandbox (`qs ssh-auth`)

`qs shell` and `qs claude` enter a sandbox from a terminal on the Mac that
hosts it. `qs ssh-auth` adds a second way in — `ssh qs-NAME@your-mac` — so a
sandbox can serve as a **remote environment**: for Claude Code Desktop's SSH
connections, an editor's remote mode, or simply a shell from another machine.

```bash
qs ssh-auth work                      # enable; authorizes your ~/.ssh/id_*.pub
qs ssh-auth work ~/laptop.pub         # authorize another key (each run adds one)
qs ssh-auth work 'ssh-ed25519 AAAA… me@laptop'   # …or a pasted key line
qs ssh-auth work off                  # revoke every key, remove the sshd config

ssh qs-work@your-mac.local            # interactive shell, like `qs shell work`
ssh qs-work@your-mac.local 'cd project && git status'   # one command; scp and sftp work too
```

Remote Login must be on (System Settings › General › Sharing › Remote Login).
qs never switches it on — that exposes sshd for the whole Mac and is your
call — but it tells you when it is off, and if Remote Login is limited to
"only these users" it adds the sandbox user to that list.

A sandbox user is an ordinary macOS account, so sshd would happily give it a
plain login shell — one that skips `sandbox-exec`, the curated environment and
the `profile.d/` hooks, i.e. most of what makes it a sandbox. `qs ssh-auth`
closes that gap in sshd itself, with a `Match User qs-NAME` block
(`/etc/ssh/sshd_config.d/010-quicksand-qs-NAME.conf`):

- **Every session is forced through a wrapper.** `ForceCommand` runs
  `config/qs-ssh-session`, which builds the same scrubbed environment as
  `qs shell`, enters the sandbox's `sandbox-exec` profile, runs the
  `profile.d/` hooks, then starts your shell or the command you asked for
  (`logout.d/` hooks run when it ends). That covers logins, `ssh host cmd`,
  scp and the sftp subsystem alike. Without a readable sandbox profile the
  wrapper refuses the session rather than run it unsandboxed.
- **The sandbox can't authorize itself.** Keys are read from
  `/var/quicksand/ssh-qs-NAME/authorized_keys`, root-owned like the wrapper —
  not from `~/.ssh/authorized_keys`, which the sandbox can write. Only bare
  public keys are accepted, and login is key-only.
- **Nothing sandbox-writable runs before the sandbox starts.** `~/.ssh/rc` is
  disabled, and `ZDOTDIR` is pinned to an empty root-owned directory so the
  shell sshd uses to start the wrapper can't pick up the sandbox's
  `~/.zshenv`.
- **Agent and X11 forwarding are off**, so your own SSH keys can't follow you
  in. TCP port forwarding is left on (the sandbox's network is unrestricted
  anyway).

The drop-in is validated before it is trusted: `sshd -t` must accept the full
configuration, and `sshd -T` must report these settings as the ones in effect
for the sandbox user (an earlier `Match` block of your own could shadow them).
If either check fails the drop-in is removed again, so a mistake can't break
SSH for the rest of the Mac. Rebuilds re-render and re-verify it; your
authorized keys are kept.

**Sandboxes without `ssh-auth` accept no SSH login at all.** Left alone, sshd
would read a sandbox user's own `~/.ssh/authorized_keys` — a file the sandbox
can write — so an agent could authorize a key of its own, `ssh` to localhost
and land in a plain shell outside `sandbox-exec`. Every build therefore
installs one shared rule, `/etc/ssh/sshd_config.d/020-quicksand-default.conf`:
for every `qs-*` user, no key file, no password, key-only authentication. It
sorts after the per-sandbox `010-` files, and sshd keeps the first value it
sees for a keyword, so a sandbox with `ssh-auth` keeps its own key list while
all others have none. Because the rule is shared, the first build after an
upgrade protects every sandbox at once. It is verified like the per-sandbox
block; a host whose sshd can't take it gets a warning rather than a failed
build, and the rule is removed when the last sandbox is uninstalled. It
applies to any account named `qs-*`, quicksand's or not.

Things that differ from a local session:

- **Host-staged credentials come through a broker.** `qs shell`/`qs claude`
  run the auth providers on the host before entering; sshd doesn't. An SSH
  session asks the host's [credential
  broker](#credentials-on-demand-qs-auth-refresh) instead, which only answers
  while you are logged in to the Mac's desktop — and 1Password has to be
  unlocked there, as for a local launch.
- **Hook output goes to stderr** for anything but a plain interactive login,
  and hooks get no stdin, so they can't corrupt or swallow a protocol stream.
  The hooks add roughly a second to each connection.
- **`-x`/`--no-sandbox` has no SSH equivalent** — SSH sessions are always
  sandboxed.

## Credentials on demand (`qs-auth-refresh`)

Two credentials are deliberately short-lived and put into a sandbox *by the
host*: the GCP access token (valid about an hour) and the 1Password
service-account token (staged per session, never stored). `qs shell` and
`qs claude` stage them just before entering. That leaves two gaps: a session
that doesn't start from `qs` — an SSH login — never gets them, and a session
that runs longer than an hour outlives its GCP token.

A host-side broker closes both. Every build stages `config/qs-auth-broker`
under `~/.config/quicksand/` and [Quicksand.app](#quicksandapp), running in
your GUI session, starts it for each request on
`/Users/Shared/quicksand/auth.sock`. Inside the sandbox:

```bash
qs-auth-refresh     # ask the host to re-stage this sandbox's credentials
```

SSH sessions run it automatically at login (`profile.d/11-auth-refresh.sh`),
before `~/.zshrc` is sourced, so they start with the same credentials a local
session has. In a long session, run it yourself when `gcloud` starts failing;
`gcloud` picks the new token up immediately. `OP_SERVICE_ACCOUNT_TOKEN` is an
environment variable, so shells already running keep the old value — new
shells get the new one.

The broker runs the same providers (`libexec/qs-auth-*`) with the same
`refresh` a launch runs, as you:

- **The sandbox can ask for exactly one thing.** The request is the single
  word `refresh`; nothing the sandbox sends reaches a command line, and which
  sandbox is refreshed is fixed by the caller's uid, not the request. The worst
  a hostile sandbox can do is make the host re-stage that sandbox's own
  credentials — and, if 1Password is locked, make it ask you to unlock.
- **It reports what needs you.** Provider messages ("unlock 1Password", a
  lapsed `gcloud` login) are relayed to the session's stderr. Each provider
  has 30 seconds; one that is waiting for an approval nobody gives is abandoned
  with a note, and the session continues without that credential.
- **A burst of logins is one refresh.** Requests are serialized, and one that
  had to wait for another reuses its result. The GCP provider additionally
  skips a token younger than 50 minutes.
- **It needs your desktop session.** 1Password's app integration and your
  `gcloud` login live there; with nobody logged in to the Mac (or the app
  not running) the socket has no listener, and SSH sessions say so and carry
  on.

On macOS 27, `op` started in the background reports "No accounts configured":
it learns that the desktop-app integration is on from a settings file inside
1Password's Group Container, and macOS only lets a process read that when the
app behind it has the "data from other apps" permission — your terminal does,
a background agent doesn't. The 1Password provider therefore retries a failed
read with `OP_BIOMETRIC_UNLOCK_ENABLED=true`, which states the same thing
through the environment. If a read still fails, the warning carries `op`'s own
error text.

The app gives brokers a bare `PATH`, so the `PATH` of the shell that built the
sandbox is pinned into the broker's spec — that is where `op` and `gcloud` are looked
up. If you install either later, rebuild (`qs build NAME -r`). Other
environment from your shell (a custom `CLOUDSDK_CONFIG`, an `op` session
variable) is not carried over. Requests are logged to
`~/.config/quicksand/auth-broker-NAME.log`.

Because sessions now overlap in ways that matter — a local `qs claude` beside
an SSH login, or the several short logins an SSH client makes — sessions
record themselves in `_quicksand/sessions/`, and the 1Password token is removed
only when the last one exits.

## Quicksand.app

`app/` holds a status-bar app that runs the host-side brokers — Docker,
credential refresh and speech — for every sandbox, like Docker Desktop runs
its engine. It listens on three sockets in `/Users/Shared/quicksand/`, tells
sandboxes apart by the uid of the connecting process, and starts the
sandbox's bash broker for each request from the spec qs renders under
`~/.config/quicksand/brokers/`. It also shows every sandbox (active or idle,
sessions, Docker, token ages) and every broker request from
`~/.config/quicksand/events.jsonl`. It posts a notification whenever anyone
connects to a broker (who, and which broker; the app never reads the request
itself), or with "Notify: Problems" only for refused and failed requests.

**Keep it running.** Without it, `qs-docker`, `qs-auth-refresh` and `qs-say`
fail with "Quicksand.app isn't running on the host". Turn on "Open at login"
in its menu.

```bash
app/scripts/bundle.sh && cp -R app/build/Quicksand.app ~/Applications/ && open ~/Applications/Quicksand.app
```

Sandboxes built before the app had their own LaunchAgents
(`~/Library/LaunchAgents/com.quicksand.*-broker.NAME.plist`) with sockets in
`_quicksand/`. They keep working until the next build of that sandbox, which
removes them and moves it to the app; the menu lists the sandboxes still
waiting for that. Design and details:
[docs/quicksand-app.md](docs/quicksand-app.md).

## Speech from the sandbox (`qs-say`)

`say` doesn't work inside a sandbox, and not for the reason you'd guess.
Audio output is fine — a sandbox process can drive the speakers. What's
missing is the speech engine: macOS resolves voices through a per-user XPC
service (`com.apple.accessibility.voices`, served by the `axassetsd`
LaunchAgent), and launchd loads that agent only into an **Aqua** session, a
real GUI login. A user entered through `sudo` gets a background launchd
domain instead, the agent never appears there — not even when root asks —
and `say` exits 0 having synthesized nothing (`say -o` writes a header with
zero audio bytes). Notification Center has the same gap.

So quicksand speaks from the host. Every build stages `config/qs-say-broker`
under `~/.config/quicksand/`, and [Quicksand.app](#quicksandapp), running in
*your* GUI session, the one place speech works, starts one short-lived broker
per message on `/Users/Shared/quicksand/say.sock`, so nothing runs while
idle. Inside the
sandbox, `profile.d/31-claude-say.sh` installs the `qs-say` client on the
PATH and, once per sandbox, seeds two Claude Code `Notification` hooks into
the sandbox's `~/.claude/settings.json`:

| Matcher | Fires when | Says |
|---|---|---|
| `idle_prompt` | Claude finished about 60 s ago and you haven't typed | "NAME is waiting for your input" |
| `permission_prompt`, `agent_needs_input` | a permission prompt or a background agent has been waiting on you | "NAME needs your attention" |

Deliberately no `Stop` hook: `Stop` fires after *every* response — including
when Claude ends a turn to let background agents run and will resume on its
own — and its payload carries nothing that tells "waiting for you" from
"turn over, work continues". `idle_prompt` is Claude Code's own idle
detector; the minute's delay is the price of no false alarms. (Sandboxes
seeded by the first release, which used `Stop`, are migrated automatically.)

```bash
qs-say "build finished"        # from a sandbox shell, or from Claude
```

The broker treats the sandbox as untrusted: the text is stripped of control
characters, capped at 300 bytes and piped to `say` on stdin — never parsed
by a shell, never passed as an argument, so a hostile sandbox can pick no
voice, write no file, and at worst make your Mac say something. Messages
are serialized so overlapping calls queue rather than talk over each other,
and the broker hangs up before speaking so hooks never wait for the speech.

The hooks are seeded only while `settings.json` doesn't mention `qs-say`, so
edits stick: delete the attention entry if permission prompts shouldn't
speak, or both to go quiet. The broker is loaded per build; on a host
without a GUI session (building over ssh) the build warns and continues
without speech.

## Claude Code settings defaults

`config/claude-settings.json` holds the Claude Code settings every sandbox
starts with:

| Key | Default | Why |
|---|---|---|
| `cleanupPeriodDays` | `3650` | Claude Code deletes session transcripts older than this (30 days if unset), and old sessions then vanish from the resume picker |
| `model` | `fable` | the model a new sandbox starts on |
| `skipDangerousModePermissionPrompt` | `true` | the sandbox is the safety boundary, so skip the bypass-permissions warning |
| `theme` | `dark` | |
| `tui` | `fullscreen` | |

The build stages the file into `_quicksand/`, and on every session entry
`profile.d/30-claude-config.sh` merges it into the sandbox's
`~/.claude/settings.json`. It is a merge, not a copy, because Claude Code
writes its own state into that file (`/model`, `/theme`, accepted prompts)
and so do you: each top-level key is added only while the sandbox's file
doesn't have it. Whatever is already set wins, and a default added to the
template later still reaches existing sandboxes on their next rebuild.

To change a default for one sandbox, edit its `settings.json`; to change it
for all new sandboxes, edit the template. Changing a value in the template
does not alter sandboxes that already have that key.

Hooks are not part of the template — the merge is top-level only, and the
`qs-say` hooks need the sandbox's name and seed-once behaviour (see
[Speech](#speech-from-the-sandbox-qs-say)).

## Automatic rebuilds

The install marker stores a fingerprint of everything a build bakes into a
sandbox: the qs version, the `sandbox-exec` profile template, `profile.d/`,
`logout.d/`, the `quicksand.md` and `claude-settings.json` assets, the speech and credential broker assets, the SSH session wrapper and sshd templates, and your personal overlay — contents, names, and file modes. When any of it
changes (a `git pull` of this repo, an edit to your overlay), the next
`qs shell`/`qs claude` rebuilds the sandbox automatically and tells you why.

## What gets provisioned

On every session entry, idempotent scripts from `profile.d/` run inside the
sandbox (first run installs, later runs are no-ops):

| Script | Purpose |
|---|---|
| `05-session-register.sh` | record the running session, so the 1Password token is only removed when the last one exits |
| `10-keychain.sh` | create/unlock a login keychain (fresh users have none) |
| `11-auth-refresh.sh` | install `qs-auth-refresh`; in an SSH session, ask the host for fresh credentials — see [Credentials on demand](#credentials-on-demand-qs-auth-refresh) |
| `20-install-claude.sh` | install Claude Code via its native installer |
| `21-install-gh.sh` | install the GitHub CLI (`gh`) from its release tarball |
| `22-install-op.sh` | install the 1Password CLI (`op`) from its release zip |
| `30-claude-config.sh` | seed onboarding flags, plus a `~/.claude/CLAUDE.md` import of `config/quicksand.md` describing the sandbox boundary, `gh` access and credentials; merge the defaults in `config/claude-settings.json` into `~/.claude/settings.json` — see [Claude Code settings defaults](#claude-code-settings-defaults) |
| `31-claude-say.sh` | install `qs-say` and seed Claude Code hooks so the Mac says "`<sandbox>` is waiting for your input" once Claude has been waiting on you — see [Speech](#speech-from-the-sandbox-qs-say) |
| `40-gitconfig.sh` | seed the host's git identity + `safe.directory` |
| `45-install-oh-my-zsh.sh` | Oh My Zsh + custom themes/plugins; disables auto-title so a manual tab name sticks |
| `46-install-pnpm.sh` | pnpm + Node.js 24 (pnpm as the version manager) |
| `47-install-python.sh` | uv + a managed Python 3.12 |
| `48-install-gcloud.sh` | Google Cloud SDK (`gcloud`, `gsutil`, `bq`) |
| `49-install-aws.sh` | install the AWS CLI v2 (per-user macOS `.pkg`, no sudo) |
| `50-tab-color.sh` | tint the iTerm2 tab green so a sandbox tab is obvious |
| `51-tab-name.sh` | name the tab `<sandbox> \| Claude` or `<sandbox> \| Shell` |
| `60-gh-auth.sh` | sign `gh` in with the repo-scoped token from `qs gh-auth` |
| `61-gcp-auth.sh` | point `gcloud`/`gsutil` at the impersonated token from `qs gcp-auth` |
| `62-op-auth.sh` | export `OP_SERVICE_ACCOUNT_TOKEN` from the token staged by `qs op-auth` |
| `63-docker-shim.sh` | install the `qs-docker` client staged by `qs docker` (or remove it when disabled) |
| `70-default-browser.sh` | mirror the host's default browser (forwarded as `QS_HOST_BROWSER`) so URL opens — Claude Code's `/login`, `gh` web flows — don't fall back to Safari |

After the `profile.d/` scripts run, the launcher sources the sandbox's
`~/.zshrc` before starting the session — for `qs claude`, one-off `-- command`
runs, and piped input alike, not just the interactive `qs shell` (which already
loaded it). So environment variables, `PATH` additions, and other settings you
keep in the sandbox's `~/.zshrc` are present in every session, including the one
Claude Code runs in. Sourcing is best-effort: a missing or broken `~/.zshrc`
never blocks the session. Note this is the *sandbox's* `~/.zshrc`, not your
host's — to seed it, drop a script in your [personal
overlay](#personal-overlay-configquicksandcustom)'s `profile.d/`.

Scripts in `logout.d/` are the exit-time counterpart: they run as the sandbox
user when the session ends (a normal `exit`, Ctrl-D, or quitting Claude Code),
via an `EXIT` trap in the launcher. Use them to undo anything a `profile.d/`
script set up for the host terminal — the bundled pair tints the iTerm2 tab on
entry and resets it on exit.

## Personal overlay (`~/.config/quicksand/custom/`)

Host-side additions synced into every sandbox at build time, kept out of the
repo:

```
~/.config/quicksand/custom/
├── profile.d/    # .sh scripts run after the canonical ones on every
│                 # session entry (use 50-99 prefixes; canonical is 10-49)
├── logout.d/     # .sh scripts run after the canonical ones when the
│                 # session ends
└── oh-my-zsh/    # themes/, plugins/, etc. copied into the sandbox's
                  # ~/.oh-my-zsh/custom/ after install
```

Changes here are part of the build fingerprint, so they propagate to
existing sandboxes automatically on next entry.

## Paths per sandbox

| Resource | Path |
|---|---|
| macOS user/group | `qs-NAME` |
| Home directory | `/Users/qs-NAME` |
| Shared workspace | `/Users/Shared/qs-NAME` |
| Cloned repos | `/Users/Shared/qs-NAME/repos/<repo>` (linked at `~/<repo>`) |
| Deploy keys | `/Users/Shared/qs-NAME/_quicksand/.ssh/` |
| gh tokens | `/Users/Shared/qs-NAME/_quicksand/gh-token-<repo>` |
| GCP access token & SA ref | `/Users/Shared/qs-NAME/_quicksand/gcp-token`, `gcp-sa` |
| Sudoers | `/etc/sudoers.d/50-nopasswd-for-qs-NAME` |
| Sandbox profile | `/var/quicksand/sandbox-qs-NAME.sb` |
| SSH wrapper & authorized keys (`qs ssh-auth`) | `/var/quicksand/ssh-qs-NAME/` |
| sshd `Match` block (`qs ssh-auth`) | `/etc/ssh/sshd_config.d/010-quicksand-qs-NAME.conf` |
| sshd default rule for all sandboxes | `/etc/ssh/sshd_config.d/020-quicksand-default.conf` |
| Broker sockets (Quicksand.app, all sandboxes) | `/Users/Shared/quicksand/docker.sock`, `auth.sock`, `say.sock` |
| Broker specs | `~/.config/quicksand/brokers/com.quicksand.{docker,auth,say}-broker.NAME.plist` |
| Install marker, clone & GCP manifests, staged brokers & their logs | `~/.config/quicksand/` |
| Broker event log (one JSON line per request, all sandboxes; written by `qs-event` inside Quicksand.app) | `~/.config/quicksand/events.jsonl` |

Sandbox names: up to 16 characters, `[A-Za-z0-9_-]+`.

## Troubleshooting

A misbehaving sandbox can always be rebuilt or recreated; neither deletes
files in the shared workspace:

```bash
qs build NAME -r        # force rebuild (config, permissions, ACLs)

qs uninstall NAME       # full reset; workspace files are kept if present
qs build NAME
```

Sandboxed builds that themselves use `sandbox-exec` (e.g. `swift`,
`xcodebuild`) cannot nest; run those sessions with `-x` to drop the
`sandbox-exec` layer while keeping the user-account isolation. See
[SandVault's notes on nested
sandboxes](https://github.com/webcoyote/sandvault#nested-sandboxes) — the
same applies here.

## Development

```bash
shellcheck qs profile.d/*.sh logout.d/*.sh    # lint
bats tests                      # unit tests (no sudo required)
```

CI runs both on every push (macOS runner — the tests stub the privileged
parts but need BSD userland).

## License

[MIT](LICENSE) © Ivan Drinchev. Portions are derived from
[SandVault](https://github.com/webcoyote/sandvault) © Patrick Wyatt, licensed
under the [Apache License 2.0](LICENSE-APACHE).

## Why quicksand, and thanks

The idea, the architecture, and most of the hard-won macOS details here —
user-account sandboxing, ACL inheritance for the shared workspace,
`sandbox-exec` as a second layer, keychain bootstrap for fresh users — come
from **Patrick Wyatt's [SandVault](https://github.com/webcoyote/sandvault)**.
Go star it. quicksand exists because I wanted a smaller tool shaped around my
own workflow (one sandbox per repository, deploy-key-scoped GitHub access,
fingerprint-driven rebuilds) and the best way to understand a design is to
rebuild it.

Also built on the shoulders of:

- [SandVault](https://github.com/webcoyote/sandvault) — yes, again
- [Claude Code](https://www.anthropic.com/claude) — the agent this exists for
- [ShellCheck](https://www.shellcheck.net) and
  [bats-core](https://github.com/bats-core/bats-core) — keeping 800 lines of
  bash honest
- [Oh My Zsh](https://ohmyz.sh), [pnpm](https://pnpm.io),
  [uv](https://docs.astral.sh/uv/) — the in-sandbox toolchain
