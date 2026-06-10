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
qs uninstall NAME                        remove the sandbox completely
qs list                                  list sandboxes

Short aliases: b, s, cl, c, u, l.
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

## Automatic rebuilds

The install marker stores a fingerprint of everything a build bakes into a
sandbox: the qs version, the `sandbox-exec` profile template, `profile.d/`,
`logout.d/`, and your personal overlay — contents, names, and file modes. When any of it
changes (a `git pull` of this repo, an edit to your overlay), the next
`qs shell`/`qs claude` rebuilds the sandbox automatically and tells you why.

## What gets provisioned

On every session entry, idempotent scripts from `profile.d/` run inside the
sandbox (first run installs, later runs are no-ops):

| Script | Purpose |
|---|---|
| `10-keychain.sh` | create/unlock a login keychain (fresh users have none) |
| `20-install-claude.sh` | install Claude Code via its native installer |
| `30-claude-json.sh` | seed onboarding flags so the first session isn't interactive |
| `40-gitconfig.sh` | seed the host's git identity + `safe.directory` |
| `45-install-oh-my-zsh.sh` | Oh My Zsh, plus your custom themes/plugins |
| `46-install-pnpm.sh` | pnpm + Node.js 24 (pnpm as the version manager) |
| `47-install-python.sh` | uv + a managed Python 3.12 |
| `48-install-gcloud.sh` | Google Cloud SDK (`gcloud`, `gsutil`, `bq`) |
| `50-tab-color.sh` | tint the iTerm2 tab green so a sandbox tab is obvious |

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
| Sudoers | `/etc/sudoers.d/50-nopasswd-for-qs-NAME` |
| Sandbox profile | `/var/quicksand/sandbox-qs-NAME.sb` |
| Install marker & clone manifest | `~/.config/quicksand/` |

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
