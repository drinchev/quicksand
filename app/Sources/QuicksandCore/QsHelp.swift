import Foundation

extension QsCLI {
    /// `qs --help`. Must match show_help in qs.bash while both exist (a test
    /// compares them).
    public static let helpText = #"""
    quicksand \#(version) — a macOS user-account sandbox.

    Usage:
      qs build     NAME [-r]
      qs shell     NAME [PATH] [-- args ...]
      qs claude    NAME [PATH] [-- args ...]
      qs clone     NAME URL_OR_PATH
      qs gh-auth   NAME [OWNER/REPO]
      qs memory    NAME OWNER/REPO
      qs gcp-auth  NAME PROJECT [PROJECT ...]
      qs gcp-token NAME
      qs op-auth   NAME [--write]
      qs docker    NAME [off]
      qs ssh-auth  NAME [KEY.pub | off]
      qs uninstall NAME
      qs list

    NAME is required for everything except 'list'.
    Up to \#(sandboxNameMaxLength) chars, [A-Za-z0-9_-].

    PATH is where the session starts, inside the sandbox: relative paths
    (and ~/...) are resolved against the sandbox home, so 'qs claude NAME
    repo' starts in ~/repo — where 'qs clone' links each repo. Absolute
    paths are used as-is; omitted, the session starts in the sandbox home.

    'gh-auth' sets up a repository-scoped GitHub token so 'gh' works inside
    the sandbox (open PRs and comments, read commits, branches and CI). It
    opens a prefilled fine-grained PAT creation page and stores the token you
    paste back; git push/pull keeps using the deploy key. 'clone' offers this
    automatically. OWNER/REPO may be omitted when the sandbox has one clone.

    'memory' attaches a shared memory repo: a private GitHub repo of markdown
    notes cloned to the shared workspace with its own read-write deploy key,
    indexed by qmd inside the sandbox. Agents share knowledge across sandboxes
    by pushing a semantic branch (feat/..., fix/..., chore/..., docs/...) and
    opening a PR for you to merge — nothing propagates without your review,
    and commits are authored 'qs-NAME' so history shows which sandbox wrote
    what. Different sandboxes may attach
    different memory repos. For agents to open PRs, the sandbox's gh token
    must also select the memory repo (fine-grained PATs can cover several
    repositories — pick both when creating it, or edit its repository access).

    'gcp-auth' provisions a per-sandbox Google Cloud service account so
    'gcloud'/'gsutil' work inside the sandbox. PROJECT is the project to grant read
    access on; pass several to span e.g. the sandbox's own project and a separate
    shared Artifact Registry project. The service account's own (owner) project is
    prompted, defaulting to your active gcloud project. It creates the SA 'qs-NAME',
    grants roles/viewer + roles/artifactregistry.reader on each PROJECT (override
    with QS_GCP_ROLES), lets your host impersonate the SA, mints a short-lived
    access token into the sandbox, and pins the first PROJECT as the default.
    'uninstall' unbinds the roles and deletes the SA. Downloadable keys are
    intentionally not used (orgs commonly disable them); the token lasts ~1h, so
    'gcp-token' re-mints one without redoing the SA/role setup.

    'docker' lets the sandbox run containers on the host Docker engine (OrbStack,
    Docker Desktop) WITHOUT seeing the Docker socket — raw socket access would be
    host-user-equivalent (bind-mount any host path). Instead a host-side broker,
    loaded as a socket-activated LaunchAgent and staged where the sandbox can't
    edit it, accepts a constrained JSON request over a workspace socket and
    composes every docker invocation from a fixed hardened template: mounts are
    limited to the shared workspace, capabilities dropped, resources capped, and
    everything is labeled per sandbox so 'uninstall' can reap it. Inside the
    sandbox the 'qs-docker' client offers run/build/pull/ps/logs/stop; built
    image tags are forced under 'qs-NAME/'. 'qs docker NAME off' disables it.

    'ssh-auth' lets you SSH into the sandbox as its user ('ssh qs-NAME@host'),
    e.g. to use it as a remote environment for Claude Code. KEY.pub is a public
    key file (or a quoted 'ssh-ed25519 AAAA...' line) to authorize; each run adds
    one, and with none given the first run authorizes your own ~/.ssh/id_*.pub.
    Every SSH session — login shell, 'ssh host cmd', scp, sftp — is forced through
    a root-owned wrapper that enters the same sandbox-exec profile, environment
    and profile.d hooks as 'qs shell'. Authorized keys live in a root-owned file,
    so nothing inside the sandbox can grant itself access or shed the sandbox.
    Requires Remote Login to be on (System Settings > General > Sharing); qs does
    not switch it on for you. Credentials the host stages at launch (1Password
    token, GCP token) are fetched for SSH logins through a host-side broker, which
    needs you logged in to the Mac's desktop. 'qs ssh-auth NAME off'
    revokes all keys and removes the sshd configuration. A sandbox without
    'ssh-auth' accepts no SSH login at all: every build installs one sshd rule
    for all qs-* users that ignores their own ~/.ssh/authorized_keys.

    'op-auth' sets up per-sandbox app-secret access via 1Password. Using your own
    host 1Password (so it must be signed in), it creates a vault 'qs-NAME', a
    service account scoped to just that vault (read-only; '--write' also grants
    write), and stores the service-account token in that vault. On every launch the
    host reads the token from 1Password into a transient file the session exports as
    OP_SERVICE_ACCOUNT_TOKEN, so the sandbox fetches secrets on demand with
    'op read'/'op run' — they are never written to the sandbox disk, and the token
    never persists between sessions. 'uninstall' prints a reminder to revoke the
    token (1Password has no CLI revoke) and leaves the vault intact.

    Options:
      -r, --rebuild        Rebuild configuration and file permissions/ACLs.
      -n, --no-build       Refuse to make sandbox changes; error if any are needed.
      -x, --no-sandbox     Disable sandbox-exec restrictions (still switches users).
      --write              (qs op-auth) grant the service account write access too.
      -v, --verbose        More output (-vv, -vvv for even more).
      --version            Show version.
      -h, --help           Show this help.

    Arguments after -- are passed to the spawned shell.

    Environment:
      QUICKSAND_ARGS       Default arguments, prepended to the command line.

    Customization:
      ~/.config/quicksand/custom/<subsystem>/
                           Host-side personal additions, grouped by subsystem.
                           Synced into the sandbox at build time. Recognised
                           subdirs:
                             profile.d/   .sh scripts run after the canonical
                                          profile.d/ on every session entry
                                          (use 50-99 prefixes to continue from
                                          the 10-49 canonical range)
                             logout.d/    .sh scripts run after the canonical
                                          logout.d/ when the session ends
                             oh-my-zsh/   themes/, plugins/, etc. copied into
                                          the sandbox's ~/.oh-my-zsh/custom/
                                          after install
    """#
}
