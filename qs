#!/bin/bash
# qs — quicksand sandbox manager for macOS.
# Creates a per-named sandbox user (qs-NAME) and runs zsh as that user
# under sandbox-exec with read/write restricted to its home and a shared
# workspace.
set -Eeuo pipefail
trap 'echo >&2 "${BASH_SOURCE[0]}: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR

readonly VERSION="0.1.0"
readonly SANDBOX_NAME_MAX_LEN=16

# Resolve the directory holding qs (and its sibling profile.d/) following
# any chain of symlinks. Mirrors `readlink -f`, which macOS bash lacks.
QS_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$QS_SOURCE" ]]; do
    QS_SOURCE_DIR="$(cd -P "$(dirname "$QS_SOURCE")" && pwd -P)"
    QS_SOURCE="$(readlink "$QS_SOURCE")"
    [[ "$QS_SOURCE" = /* ]] || QS_SOURCE="$QS_SOURCE_DIR/$QS_SOURCE"
done
readonly QS_REPO_DIR="$(cd -P "$(dirname "$QS_SOURCE")" && pwd -P)"
readonly QS_PROFILE_SOURCE_DIR="$QS_REPO_DIR/profile.d"

QS_VERBOSE="${QS_VERBOSE:-0}"
abort() { echo >&2 "ERROR: $*"; exit 1; }
warn()  { echo >&2 "WARNING: $*"; }
info()  { echo "$*"; }
debug() { (( QS_VERBOSE >= 2 )) && echo "$*" || true; }
trace() { (( QS_VERBOSE >= 3 )) && echo "$*" || true; }

[[ $OSTYPE == 'darwin'* ]]      || abort "this script is for macOS"
[[ $EUID -ne 0 ]]               || abort "this script should not be run as root"
[[ -z "${QS_SESSION_ID:-}" ]]   || abort "already inside a quicksand sandbox"

heredoc() { IFS=$'\n' read -r -d '' "${1}" || true; }

# Quote args for safe interpolation into a `/bin/zsh -c` string.
quote_zsh_args() {
    /bin/zsh -fc 'for arg; do printf "%s " "${(q)arg}"; done' -- "$@"
}

validate_sandbox_name() {
    local name="$1"
    [[ -n "$name" ]] || abort "sandbox name required"
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] \
        || abort "sandbox name must contain only letters, digits, '-' and '_' (got: $name)"
    (( ${#name} <= SANDBOX_NAME_MAX_LEN )) \
        || abort "sandbox name must be ${SANDBOX_NAME_MAX_LEN} characters or fewer (got ${#name})"
}

show_version() { echo "qs version $VERSION"; exit 0; }

show_help() {
    cat <<EOF
quicksand $VERSION — a macOS user-account sandbox.

Usage:
  qs build     NAME [-r]
  qs shell     NAME [PATH] [-- args ...]
  qs claude    NAME [PATH] [-- args ...]
  qs uninstall NAME
  qs list

NAME is required for everything except 'list'.
Up to ${SANDBOX_NAME_MAX_LEN} chars, [A-Za-z0-9_-].

Options:
  -r, --rebuild        Rebuild configuration and file permissions/ACLs.
  -n, --no-build       Refuse to make sandbox changes; error if any are needed.
  -x, --no-sandbox     Disable sandbox-exec restrictions (still switches users).
  -v, --verbose        More output (-vv, -vvv for even more).
  --version            Show version.
  -h, --help           Show this help.

Arguments after -- are passed to the spawned shell.

Environment:
  QUICKSAND_ARGS       Default arguments, prepended to the command line.

Customization:
  ~/.config/quicksand/profile.d/*.sh
                       Personal scripts overlaid on top of the canonical
                       profile.d/ at build time, run on every session
                       entry. Use 50-99 prefixes to avoid clashing with
                       the canonical 10-49 range.
EOF
    exit 0
}

list_sandboxes() {
    echo "Sandboxes:"
    local home name found=false
    shopt -s nullglob
    for home in /Users/qs-*/; do
        name="${home#/Users/qs-}"
        name="${name%/}"
        printf "  %s\n" "$name"
        found=true
    done
    shopt -u nullglob
    [[ "$found" == "true" ]] || echo "  (none — run 'qs build <NAME>')"
}


###############################################################################
# Argument parsing
###############################################################################
REBUILD=false
NO_BUILD=false
USE_SANDBOX=true
SANDBOX_NAME=""
COMMAND=""
COMMAND_ARGS=()
INITIAL_DIR=""

if [[ -n "${QUICKSAND_ARGS:-}" ]]; then
    qs_args_array=()
    while IFS= read -r arg; do qs_args_array+=("$arg"); done \
        < <(xargs -n1 printf '%s\n' <<< "$QUICKSAND_ARGS")
    set -- "${qs_args_array[@]}" "$@"
fi

NEW_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --) shift; while [[ $# -gt 0 ]]; do COMMAND_ARGS+=("$1"); shift; done; break ;;
        -r|--rebuild)    REBUILD=true; shift ;;
        -n|--no-build)   NO_BUILD=true; shift ;;
        -x|--no-sandbox) USE_SANDBOX=false; shift ;;
        -v|--verbose)    ((QS_VERBOSE++)) || true; shift ;;
        -vv)             ((QS_VERBOSE+=2)) || true; shift ;;
        -vvv)            ((QS_VERBOSE+=3)) || true; shift ;;
        --version) show_version ;;
        -h|--help) show_help ;;
        -*) abort "Unknown option: $1" ;;
        *)  NEW_ARGS+=("$1"); shift ;;
    esac
done
if (( ${#NEW_ARGS[@]} > 0 )); then set -- "${NEW_ARGS[@]}"; else set --; fi

# Form: qs COMMAND [NAME [PATH]]
[[ $# -ge 1 ]] || show_help

case "$1" in
    l|list)      list_sandboxes; exit 0 ;;
    s|shell)     COMMAND=shell;  needs_name=true  ;;
    cl|claude)   COMMAND=claude; needs_name=true  ;;
    b|build)     COMMAND=build;  needs_name=true  ;;
    u|uninstall) COMMAND=uninstall; needs_name=true ;;
    *)           abort "Unknown command: $1 (try: qs --help)" ;;
esac
readonly COMMAND

if [[ "${needs_name:-false}" == "true" ]]; then
    [[ $# -ge 2 ]] || abort "sandbox name required after '$1' (try: qs --help)"
    validate_sandbox_name "$2"
    SANDBOX_NAME="$2"
    if [[ "$COMMAND" == "shell" || "$COMMAND" == "claude" ]]; then
        INITIAL_DIR="${3:-}"
    fi
fi


###############################################################################
# Sandbox identifiers
###############################################################################
readonly SANDBOX_NAME
readonly QUICKSAND_USER="qs-$SANDBOX_NAME"
readonly QUICKSAND_GROUP="qs-$SANDBOX_NAME"
readonly SHARED_WORKSPACE="/Users/Shared/qs-$SANDBOX_NAME"
readonly QS_PRIVATE_DIR="$SHARED_WORKSPACE/_quicksand"
readonly QS_PROFILE_DIR="$QS_PRIVATE_DIR/profile.d"
readonly SUDOERS_FILE="/etc/sudoers.d/50-nopasswd-for-$QUICKSAND_USER"
readonly SANDBOX_PROFILE="/var/quicksand/sandbox-$QUICKSAND_USER.sb"
readonly INSTALL_DIR="$HOME/.config/quicksand"
readonly INSTALL_MARKER="$INSTALL_DIR/install-$SANDBOX_NAME"
# Host-side personal overlay. Anything dropped here is rsync'd on top of
# the repo's canonical profile.d/ into every sandbox during build.
# Convention: 50-99 prefixes for personal scripts; 10-49 are canonical.
readonly QS_HOST_OVERLAY_DIR="$INSTALL_DIR/profile.d"
readonly HOST_USER="$USER"
readonly QS_SESSION_ID="$(/usr/bin/uuidgen)"

# Two ACEs per directory + one per file: prevents files from inheriting
# search/list (which on a file means execute) from their parent.
readonly QS_DIR_RIGHTS="group:$QUICKSAND_GROUP allow read,write,append,delete,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,writesecurity,chown,search,list,directory_inherit"
readonly QS_FILE_INHERIT_RIGHTS="group:$QUICKSAND_GROUP allow read,write,append,delete,readattr,writeattr,readextattr,writeextattr,readsecurity,writesecurity,chown,file_inherit,directory_inherit,only_inherit"
readonly QS_FILE_RIGHTS="group:$QUICKSAND_GROUP allow read,write,append,delete,readattr,writeattr,readextattr,writeextattr,readsecurity,writesecurity,chown"

# Translate ~ in PATH arg to the sandbox user's home, then resolve symlinks.
if [[ "$INITIAL_DIR" == "~" ]]; then
    INITIAL_DIR="/Users/$QUICKSAND_USER"
elif [[ "${INITIAL_DIR:0:2}" == "~/" ]]; then
    INITIAL_DIR="/Users/$QUICKSAND_USER/${INITIAL_DIR:2}"
fi
INITIAL_DIR="$(cd "${INITIAL_DIR:-$PWD}" 2>/dev/null && pwd -P || echo "$INITIAL_DIR")"
readonly INITIAL_DIR

# Missing install marker → force a (re)build, except when uninstalling.
if [[ ! -f "$INSTALL_MARKER" && "$COMMAND" != "uninstall" ]]; then
    REBUILD=true
    QS_VERBOSE=$(( QS_VERBOSE > 1 ? QS_VERBOSE : 1 ))
fi

if [[ "$NO_BUILD" == "true" ]]; then
    [[ "$COMMAND" != "build" ]]    || abort "refusing build with --no-build set"
    [[ "$COMMAND" != "uninstall" ]] || abort "refusing uninstall with --no-build set"
    [[ "$REBUILD" == "false" ]]    || abort "sandbox '$SANDBOX_NAME' is not installed"
fi
readonly NO_BUILD REBUILD USE_SANDBOX


###############################################################################
# Shared helpers (after constants)
###############################################################################
configure_shared_folder_permissions() {
    local enable="$1"
    if [[ "$enable" == "true" ]]; then
        trace "Configuring $SHARED_WORKSPACE ownership and ACLs"
        sudo /usr/sbin/chown -f -R "$HOST_USER:$QUICKSAND_GROUP" "$SHARED_WORKSPACE"
        sudo /bin/chmod 0770 "$SHARED_WORKSPACE"
        sudo find "$SHARED_WORKSPACE" \
            \( -type d -exec /bin/chmod -h +a "$QS_DIR_RIGHTS"          {} + \
                       -exec /bin/chmod -h +a "$QS_FILE_INHERIT_RIGHTS" {} + \) \
            -o \
            \( ! -type d -exec /bin/chmod -h +a "$QS_FILE_RIGHTS"       {} + \)
    else
        trace "Restoring $SHARED_WORKSPACE to host user"
        sudo /usr/sbin/chown -f -R "$HOST_USER:$(id -gn)" "$SHARED_WORKSPACE"
        sudo /bin/chmod 0700 "$SHARED_WORKSPACE"
        sudo find "$SHARED_WORKSPACE" -exec /bin/chmod -h -N {} + 2>/dev/null || true
    fi
}

# Pick the first free integer ID at/above QS_MIN_ID, scanning both user
# UIDs and group GIDs together so groups and users never collide.
QS_MIN_ID="${QS_MIN_ID:-600}"
next_free_id() {
    local taken
    taken=$( { dscl . -list /Users UniqueID; dscl . -list /Groups PrimaryGroupID; } \
        | awk '{print $2}' | sort -un)
    awk -v min="$QS_MIN_ID" '
        BEGIN { n = min; p = 0 }
        { if ($1 < n) next; if ($1 == n) { n++; next } print n; p = 1; exit }
        END { if (!p) print n }
    ' <<< "$taken"
}

# Coarse advisory lock so concurrent `qs build` runs don't race on ID
# allocation. mkdir is atomic on POSIX; the first creator wins.
QS_ID_LOCK_DIR="/tmp/quicksand-id-alloc.lock"
acquire_id_lock() {
    local waited=0
    while ! mkdir "$QS_ID_LOCK_DIR" 2>/dev/null; do
        local holder=""
        [[ -r "$QS_ID_LOCK_DIR/pid" ]] && holder=$(cat "$QS_ID_LOCK_DIR/pid" 2>/dev/null || true)
        if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
            warn "Removing stale ID-allocation lock from PID $holder"
            rm -rf "$QS_ID_LOCK_DIR"
            continue
        fi
        (( waited < 30 )) || abort "Timed out waiting for ID-allocation lock at $QS_ID_LOCK_DIR"
        sleep 1; waited=$((waited+1))
    done
    echo "$$" > "$QS_ID_LOCK_DIR/pid"
    trap 'rm -rf "$QS_ID_LOCK_DIR"' EXIT
}
release_id_lock() { rm -rf "$QS_ID_LOCK_DIR"; trap - EXIT; }

uninstall() {
    info "Uninstalling sandbox '$SANDBOX_NAME'..."

    # Best-effort: tear down any running session for this sandbox user.
    local uid
    if uid=$(dscl . -read "/Users/$QUICKSAND_USER" UniqueID 2>/dev/null | awk '{print $2}') \
        && [[ -n "$uid" ]]; then
        sudo launchctl bootout "user/$uid" 2>/dev/null || true
        sleep 0.2
    fi
    if pgrep -u "$QUICKSAND_USER" >/dev/null 2>&1; then
        sudo pkill -9 -u "$QUICKSAND_USER" 2>/dev/null || true
    fi

    rm -f  "$INSTALL_MARKER"
    rmdir  "$INSTALL_DIR" 2>/dev/null || true
    sudo rm -f "$SUDOERS_FILE" "$SANDBOX_PROFILE"
    sudo rmdir "$(dirname "$SANDBOX_PROFILE")" 2>/dev/null || true

    if [[ -d "$SHARED_WORKSPACE" ]]; then
        configure_shared_folder_permissions false
    fi

    sudo dseditgroup -o edit -d "$HOST_USER" -t user "$QUICKSAND_GROUP" 2>/dev/null || true
    sudo dscl . -delete "/Users/$QUICKSAND_USER"  &>/dev/null || true
    sudo dscl . -delete "/Groups/$QUICKSAND_GROUP" &>/dev/null || true
    sudo rm -rf "/Users/$QUICKSAND_USER"

    rm -rf "$QS_PRIVATE_DIR"
    rmdir "$SHARED_WORKSPACE" 2>/dev/null || true
    [[ -d "$SHARED_WORKSPACE" ]] && info "Keeping $SHARED_WORKSPACE (not empty)"
    info "Sandbox '$SANDBOX_NAME' removed."
}


###############################################################################
# Uninstall short-circuit
###############################################################################
if [[ "$COMMAND" == "uninstall" ]]; then
    uninstall
    exit 0
fi


###############################################################################
# Build
###############################################################################
if [[ "$REBUILD" == "true" ]]; then
    info "Building sandbox '$SANDBOX_NAME'..."

    # A restrictive host umask leaves /var/quicksand and the sandbox profile
    # unreadable by the sandbox user. Force the standard mask for the duration
    # of the build so files we create are world-traversable where needed.
    umask 022

    sudo "-p Password required to create the quicksand sandbox: " true

    acquire_id_lock

    if ! dscl . -read "/Groups/$QUICKSAND_GROUP" &>/dev/null; then
        trace "Creating group $QUICKSAND_GROUP"
        sudo dscl . -create "/Groups/$QUICKSAND_GROUP"
        GROUP_ID=$(next_free_id)
    else
        GROUP_ID=$(dscl . -read "/Groups/$QUICKSAND_GROUP" PrimaryGroupID 2>/dev/null | awk '{print $2}')
        [[ -n "${GROUP_ID:-}" ]] || GROUP_ID=$(next_free_id)
    fi
    trace "Configuring $QUICKSAND_GROUP (GID=$GROUP_ID)"
    sudo dscl . -create "/Groups/$QUICKSAND_GROUP" PrimaryGroupID "$GROUP_ID"
    sudo dscl . -create "/Groups/$QUICKSAND_GROUP" RealName "$QUICKSAND_GROUP Group"

    if ! dscl . -read "/Users/$QUICKSAND_USER" &>/dev/null; then
        trace "Creating user $QUICKSAND_USER"
        sudo dscl . -create "/Users/$QUICKSAND_USER"
        USER_ID=$(next_free_id)
    else
        USER_ID=$(dscl . -read "/Users/$QUICKSAND_USER" UniqueID 2>/dev/null | awk '{print $2}')
        [[ -n "${USER_ID:-}" ]] || USER_ID=$(next_free_id)
    fi
    trace "Configuring $QUICKSAND_USER (UID=$USER_ID)"
    sudo dscl . -create "/Users/$QUICKSAND_USER" UniqueID         "$USER_ID"
    sudo dscl . -create "/Users/$QUICKSAND_USER" PrimaryGroupID   "$GROUP_ID"
    sudo dscl . -create "/Users/$QUICKSAND_USER" RealName         "$QUICKSAND_USER User"
    sudo dscl . -create "/Users/$QUICKSAND_USER" NFSHomeDirectory "/Users/$QUICKSAND_USER"
    sudo dscl . -create "/Users/$QUICKSAND_USER" UserShell        "/bin/zsh"
    sudo dscl . -create "/Users/$QUICKSAND_USER" IsHidden         1
    sudo dscl . -passwd "/Users/$QUICKSAND_USER" "$(openssl rand -base64 32)"

    # Strip from `staff` so the sandbox user can't reach files group-readable
    # by default on macOS. macOS keeps two parallel membership representations
    # (username + GeneratedUID); clear both.
    trace "Removing $QUICKSAND_USER from staff"
    QS_GUID="$(dscl . -read "/Users/$QUICKSAND_USER" GeneratedUID 2>/dev/null \
        | awk '/^GeneratedUID:/ {print $2}' || true)"
    sudo dseditgroup -o edit -d "$QUICKSAND_USER" -t user staff 2>/dev/null || true
    [[ -n "${QS_GUID:-}" ]] \
        && sudo dscl . -delete "/Groups/staff" GroupMembers "$QS_GUID" 2>/dev/null || true
    sudo dscl . -delete "/Groups/staff" GroupMembership "$QUICKSAND_USER" 2>/dev/null || true

    sudo dseditgroup -o edit -a "$QUICKSAND_USER" -t user "$QUICKSAND_GROUP"
    sudo dseditgroup -o edit -a "$HOST_USER"      -t user "$QUICKSAND_GROUP"

    release_id_lock

    # Shared workspace
    debug "Creating $SHARED_WORKSPACE"
    mkdir -p "$SHARED_WORKSPACE"
    configure_shared_folder_permissions true
    cat > "$SHARED_WORKSPACE/QUICKSAND-README.md" <<EOF
# quicksand workspace for $HOST_USER (sandbox: $SANDBOX_NAME)
# (autogenerated; do not edit)

Shared between $HOST_USER and $QUICKSAND_USER. Enter the sandbox with:

    qs shell $SANDBOX_NAME
EOF

    # Sudoers
    debug "Writing sudoers"
    heredoc SUDOERS_CONTENT <<EOF
# Allow $HOST_USER to switch to $QUICKSAND_USER without a password
$HOST_USER ALL=($QUICKSAND_USER) NOPASSWD: /bin/zsh
$HOST_USER ALL=($QUICKSAND_USER) NOPASSWD: /usr/bin/env
$HOST_USER ALL=($QUICKSAND_USER) NOPASSWD: /usr/bin/true
EOF
    # Validate via visudo on a temp file, then atomically move into place.
    SUDOERS_TMP="$(sudo /usr/bin/mktemp "$(dirname "$SUDOERS_FILE")/.sudoers.XXXXXX")"
    # shellcheck disable=SC2154 # set by heredoc above
    echo "$SUDOERS_CONTENT" | sudo tee "$SUDOERS_TMP" > /dev/null
    sudo /bin/chmod 0440 "$SUDOERS_TMP"
    if sudo visudo -c -f "$SUDOERS_TMP" &>/dev/null; then
        sudo /bin/mv -f "$SUDOERS_TMP" "$SUDOERS_FILE"
    else
        sudo rm -f "$SUDOERS_TMP"
        abort "Failed to create valid sudoers file"
    fi

    # Sandbox profile
    debug "Writing sandbox profile"
    sudo mkdir -p "$(dirname "$SANDBOX_PROFILE")"
    sudo /bin/chmod 0755 "$(dirname "$SANDBOX_PROFILE")"
    heredoc SANDBOX_PROFILE_CONTENT <<EOF
;; quicksand sandbox profile for $QUICKSAND_USER
(version 1)
(allow default)

;; Block all writes by default, then re-allow specific subpaths below.
(deny file-write*
    (subpath "/"))

;; Hide removable volumes; keep the boot volume readable via /Volumes.
(deny file-read*
    (subpath "/Volumes"))
(allow file-read*
    (subpath "/Volumes/Macintosh HD"))

;; Raw disks and packet capture — denied even though POSIX perms already
;; block them. Defense in depth.
(deny file-read* file-write*
    (regex #"^/dev/r?disk")
    (regex #"^/private/dev/r?disk")
    (regex #"^/dev/bpf"))

;; Hide other users' homes; re-allow only this sandbox user's home and the
;; shared workspace. The literal /Users and /Users/Shared re-allows grant
;; lookup so path traversal into the allowed subpaths still works.
(deny file-read*
    (subpath "/Users"))
(allow file-read*
    (literal "/Users")
    (literal "/Users/Shared")
    (subpath "$SHARED_WORKSPACE")
    (subpath "/Users/$QUICKSAND_USER"))

;; System.keychain is world-readable on stock macOS; deny is load-bearing.
(deny file-read*
    (subpath "/Library/Keychains"))

(allow file-write*
    (subpath "$SHARED_WORKSPACE")
    (subpath "/Users/$QUICKSAND_USER")
    (subpath "/tmp")
    (subpath "/private/tmp")
    (subpath "/var/folders")
    (subpath "/private/var/folders")
    (subpath "/dev"))

(allow process-info*)
(allow sysctl-read)
(allow process*)
(allow process-exec
    (literal "/bin/ps")
    (with no-sandbox))
EOF
    # shellcheck disable=SC2154 # set by heredoc above
    echo "$SANDBOX_PROFILE_CONTENT" | sudo tee "$SANDBOX_PROFILE" > /dev/null
    sudo /bin/chmod 0444 "$SANDBOX_PROFILE"

    # Home directory
    debug "Creating /Users/$QUICKSAND_USER"
    sudo mkdir -p "/Users/$QUICKSAND_USER"
    sudo chown "$QUICKSAND_USER:$QUICKSAND_GROUP" "/Users/$QUICKSAND_USER"
    sudo /bin/chmod 0750 "/Users/$QUICKSAND_USER"

    # Per-session profile scripts live in profile.d/ at the repo root, are
    # synced into the sandbox's shared workspace here, and run as the
    # sandbox user on every session start (see the loop in ZSH_COMMAND).
    # Each is responsible for being idempotent so re-runs are no-ops.
    [[ -d "$QS_PROFILE_SOURCE_DIR" ]] \
        || abort "profile.d directory missing at $QS_PROFILE_SOURCE_DIR"
    debug "Syncing $QS_PROFILE_SOURCE_DIR/ → $QS_PROFILE_DIR/"
    mkdir -p "$QS_PROFILE_DIR"
    # --checksum so unchanged scripts don't get their mtimes bumped.
    # No --delete: user-added scripts in $QS_PROFILE_DIR survive rebuilds;
    # canonical scripts from profile.d/ are overwritten.
    /usr/bin/rsync \
        --checksum --recursive --perms --times \
        "$QS_PROFILE_SOURCE_DIR/" "$QS_PROFILE_DIR/"

    # Host overlay (optional). Personal scripts under $QS_HOST_OVERLAY_DIR
    # land on top — identical filenames overwrite the canonical ones, new
    # filenames join the lex-sorted run. Auto-detected; absent dir is a
    # no-op.
    if [[ -d "$QS_HOST_OVERLAY_DIR" ]]; then
        debug "Overlaying $QS_HOST_OVERLAY_DIR/ → $QS_PROFILE_DIR/"
        /usr/bin/rsync \
            --checksum --recursive --perms --times \
            "$QS_HOST_OVERLAY_DIR/" "$QS_PROFILE_DIR/"
    fi

    mkdir -p "$INSTALL_DIR"
    date > "$INSTALL_MARKER"
fi

if [[ "$COMMAND" == "build" ]]; then
    info "Sandbox '$SANDBOX_NAME' ready."
    exit 0
fi


###############################################################################
# Pre-launch sanity checks
###############################################################################
SV_DIR="$(dirname "$SANDBOX_PROFILE")"
if [[ -d "$SV_DIR" ]]; then
    perms=$(/usr/bin/stat -f "%Lp" "$SV_DIR")
    if [[ "$((8#$perms & 8#0005))" -eq 0 ]]; then
        warn "$SV_DIR has restrictive permissions ($perms). Run: qs build $SANDBOX_NAME --rebuild"
    fi
fi
if [[ -f "$SANDBOX_PROFILE" && ! -r "$SANDBOX_PROFILE" ]]; then
    warn "Cannot read $SANDBOX_PROFILE. Run: qs build $SANDBOX_NAME --rebuild"
fi

trace "Checking passwordless sudo"
if ! sudo --non-interactive --user="$QUICKSAND_USER" /usr/bin/true; then
    abort "Passwordless sudo to $QUICKSAND_USER not configured. Run: qs build $SANDBOX_NAME --rebuild"
fi


###############################################################################
# Launch
###############################################################################
INITIAL_DIR_Q="$(quote_zsh_args "${INITIAL_DIR:-/Users/$QUICKSAND_USER}")"
# TMPDIR is per-session so tools that name temp dirs after themselves
# (e.g. /tmp/claude) don't collide across sandbox users.
ZSH_COMMAND="export TMPDIR=\$(mktemp -d); cd $INITIAL_DIR_Q 2>/dev/null || cd ~"

# Run per-session profile scripts (as the sandbox user, inside the
# sandbox). `*.sh(N)` matches only .sh files; `(N)` is zsh's null-glob
# qualifier — empty match when no scripts exist. SHARED_WORKSPACE is
# built from a validated [A-Za-z0-9_-] name so it needs no further
# quoting.
ZSH_COMMAND="$ZSH_COMMAND; for s in $SHARED_WORKSPACE/_quicksand/profile.d/*.sh(N); do [[ -x \"\$s\" ]] && \"\$s\"; done"

if [[ "$COMMAND" == "claude" ]]; then
    # sandbox-exec is already restricting file writes to the sandbox home
    # plus the shared workspace, so claude's per-action permission prompts
    # are redundant. `bypassPermissionsModeAccepted: true` (seeded by the
    # 30-claude-json.sh profile script) is the on-disk acknowledgement.
    ZSH_COMMAND="$ZSH_COMMAND; exec $(quote_zsh_args claude --dangerously-skip-permissions "${COMMAND_ARGS[@]+"${COMMAND_ARGS[@]}"}")"
elif (( ${#COMMAND_ARGS[@]} > 0 )); then
    ZSH_COMMAND="$ZSH_COMMAND; exec $(quote_zsh_args "${COMMAND_ARGS[@]}")"
elif [[ -t 0 ]]; then
    ZSH_COMMAND="$ZSH_COMMAND; exec /bin/zsh -i"
else
    # Piped stdin: non-interactive zsh, no prompt or interactive hooks.
    ZSH_COMMAND="$ZSH_COMMAND; exec /bin/zsh"
fi

SANDBOX_EXEC=()
if [[ "$USE_SANDBOX" == "true" ]]; then
    SANDBOX_EXEC=(/usr/bin/sandbox-exec -f "$SANDBOX_PROFILE")
else
    debug "Sandbox disabled (--no-sandbox)"
fi

EXTRA_ENV=()
[[ -n "${COLORTERM:-}" ]] && EXTRA_ENV+=("COLORTERM=$COLORTERM")

# Host git identity, consumed by profile.d/40-gitconfig.sh inside the sandbox.
# Resolved at every invocation (not pinned at build time) so updates to
# `git config --global` on the host propagate on the next session — but
# only into sandboxes that don't already have ~/.gitconfig (the profile
# script is idempotent).
QS_GIT_USER_NAME="$(git config --global --get user.name  2>/dev/null || true)"
QS_GIT_USER_EMAIL="$(git config --global --get user.email 2>/dev/null || true)"
[[ -n "$QS_GIT_USER_NAME"  ]] && EXTRA_ENV+=("QS_GIT_USER_NAME=$QS_GIT_USER_NAME")
[[ -n "$QS_GIT_USER_EMAIL" ]] && EXTRA_ENV+=("QS_GIT_USER_EMAIL=$QS_GIT_USER_EMAIL")

# PATH inside the sandbox: only system binaries plus the sandbox user's
# own install locations. Host Homebrew is intentionally *not* on this PATH
# — tools belong inside the sandbox, where the install-claude profile
# script (and anything else you add) places them.
SANDBOX_PATH="/Users/$QUICKSAND_USER/.local/bin:/Users/$QUICKSAND_USER/.claude/local:/usr/bin:/bin:/usr/sbin:/sbin"

debug "Entering sandbox $QUICKSAND_USER"
exec sudo --login --set-home --user="$QUICKSAND_USER" \
    /usr/bin/env -i \
        "HOME=/Users/$QUICKSAND_USER" \
        "USER=$QUICKSAND_USER" \
        "SHELL=/bin/zsh" \
        "TERM=${TERM:-}" \
        "SHARED_WORKSPACE=$SHARED_WORKSPACE" \
        "QS_SESSION_ID=$QS_SESSION_ID" \
        "QS_SANDBOX_NAME=$SANDBOX_NAME" \
        "QS_HOST_USER=$HOST_USER" \
        "QS_VERBOSE=$QS_VERBOSE" \
        "PATH=$SANDBOX_PATH" \
        "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
        "${SANDBOX_EXEC[@]+"${SANDBOX_EXEC[@]}"}" \
        /bin/zsh -c "$ZSH_COMMAND"
