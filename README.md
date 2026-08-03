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

```bash
git clone https://github.com/drinchev/quicksand

# Option 1: add qs to your PATH
export PATH="$PATH:/path/to/quicksand"

# Option 2: alias it
echo 'alias qs="/path/to/quicksand/qs"' >> ~/.zshrc
```

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
qs uninstall NAME                        remove the sandbox completely
qs list                                  list sandboxes

Short aliases: b, s, cl, c, g, gp, gt, o, d, u, l.
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

<!-- The authoritative permission list is the PAT URL in
     libexec/qs-auth-gh — keep this section in sync with it. -->
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
`OP_SERVICE_ACCOUNT_TOKEN`; `15-op-token.sh` removes it again at session exit.
So the token is sourced fresh from 1Password each session and **never persists
in the sandbox between sessions**. Inside the sandbox:

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

The broker script is staged under `~/.config/quicksand/` and loaded as a
socket-activated LaunchAgent (`com.quicksand.docker-broker.NAME`): launchd
owns the socket and spawns one short-lived broker per connection, so nothing
runs while idle — and the code executing as your user lives host-side where
the sandbox can't edit it. The `docker`/`jq` binary paths are pinned into the
LaunchAgent at install time. Containers themselves are confined by your
engine's VM, not by `sandbox-exec`; container network egress is unrestricted,
matching quicksand's "files, not egress" model.

## Automatic rebuilds

The install marker stores a fingerprint of everything a build bakes into a
sandbox: the qs version, the `sandbox-exec` profile template, `profile.d/`,
`logout.d/`, `config/quicksand.md`, the docker broker assets, and your
personal overlay — contents, names, and file modes. When any of it
changes (a `git pull` of this repo, an edit to your overlay), the next
`qs shell`/`qs claude` rebuilds the sandbox automatically and tells you why.

## Architecture: the `qs` core and `libexec/` providers

```
qs                  # the CLI: parsing, derived constants, build, launch,
                    # uninstall, dispatch — the security-critical core
libexec/
  qs-auth-gcp       # GCP:       provision | mint | refresh | cleanup
  qs-auth-gh        # GitHub:    provision | refresh | cleanup
  qs-auth-op        # 1Password: provision [--write] | refresh | cleanup
profile.d/          # in-sandbox session hooks; 00-lib.sh holds shared
                    # helpers (sourced by hooks, deliberately not executable)
logout.d/           # in-sandbox exit hooks
config/             # sandbox.sb template, quicksand.md, docker broker+client
tests/qs.bats       # the whole suite; CI = shellcheck + bats
```

Credential integrations live behind a uniform **auth provider contract**:
each `libexec/qs-auth-NAME` is a standalone script owning one credential
domain end-to-end — interactive provisioning, launch-time refresh,
uninstall cleanup, and its own token/manifest file layout.

| verb | called by | contract |
|---|---|---|
| `provision …` | its thin `cmd_*` wrapper in `qs` | interactive setup; may fail loudly |
| `refresh` | every launch, via `run_all_auth_providers` | self-gate on own state (unprovisioned → silent no-op); never fail |
| `cleanup` | `qs uninstall`, via the same loop | reverse what provision did; best-effort, never fail |

Context arrives via a small env contract — `QS_SANDBOX_NAME`,
`QS_PRIVATE_DIR` (the workspace's `_quicksand/`, where tokens are staged),
`QS_INSTALL_DIR` (`~/.config/quicksand`, where manifests live) and
`QS_VERBOSE` — passed with `env`, not shell env-prefix assignments (the
qs globals are readonly, and bash rejects `VAR=x cmd` for readonly names).
Providers run straight from the repo checkout like `qs` itself; nothing in
`libexec/` is staged into sandboxes, so provider edits don't trigger
rebuilds.

Each host-side provider pairs with an in-sandbox consumer in `profile.d/`
(e.g. `qs-auth-gcp` stages `_quicksand/gcp-token`; `61-gcp-auth.sh` points
`gcloud` at it) — one file per side of the sandbox boundary.

### Adding a provider

1. `libexec/qs-auth-NAME` implementing the verbs above (copy an existing
   provider's skeleton; keep `refresh`/`cleanup` self-gating and
   best-effort).
2. A `profile.d/` consumer for whatever it stages into `_quicksand/`.
3. A `cmd_*` wrapper and `parse_args` case in `qs` only if it needs a
   user-facing command — launch and uninstall pick new providers up
   automatically via the loops, with no core edits.
4. Tests: source the provider for unit tests, exec it for CLI-level
   tests (see the `gcp_run`/`gcp_exec` helpers in `tests/qs.bats`).

## What gets provisioned

On every session entry, idempotent scripts from `profile.d/` run inside the
sandbox (first run installs, later runs are no-ops):

| Script | Purpose |
|---|---|
| `10-keychain.sh` | create/unlock a login keychain (fresh users have none) |
| `20-install-claude.sh` | install Claude Code via its native installer |
| `21-install-gh.sh` | install the GitHub CLI (`gh`) from its release tarball |
| `22-install-op.sh` | install the 1Password CLI (`op`) from its release zip |
| `30-claude-config.sh` | seed onboarding flags, plus a `~/.claude/CLAUDE.md` import of `config/quicksand.md` describing the sandbox boundary, `gh` access and credentials |
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
| Install marker, clone & GCP manifests | `~/.config/quicksand/` |

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
shellcheck qs libexec/* profile.d/*.sh logout.d/*.sh \
    config/qs-docker-broker config/qs-docker           # lint
bats tests                                             # unit tests (no sudo)
```

CI runs both on every push (macOS runner — the tests stub the privileged
parts but need BSD userland). Things that bite:

- **Match CI's shellcheck version.** CI installs the latest brew
  shellcheck; older local versions report findings newer ones dropped
  (0.10 flags `A && B || true` as SC2015, 0.11 doesn't). Verify with
  CI's version before trusting a local verdict.
- **Running the suite inside a quicksand sandbox** needs the session's
  own variables stripped —
  `env -u QS_SESSION_ID -u QS_SANDBOX_NAME -u QS_SESSION_KIND bats tests`
  — because sourcing `qs` refuses inside a sandbox and test helpers must
  never inherit `QS_*` defaults from the session.
- **Mirror `readonly` in tests.** `derive_constants` declares the qs
  globals readonly; tests that set them as plain variables miss a whole
  failure class (see the `run_auth_provider … readonly` regression test).

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
