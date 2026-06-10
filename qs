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
readonly QS_SANDBOX_PROFILE_TEMPLATE="$QS_REPO_DIR/config/sandbox.sb"

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

# Fingerprint of everything a build bakes into a sandbox: qs version,
# sandbox profile template, canonical profile.d/, and the host-side
# custom overlay (contents, relative names, and file modes — the exec
# bit decides whether a profile script runs). A sandbox whose install
# marker doesn't match is stale and gets rebuilt automatically.
config_fingerprint() {
    {
        echo "$VERSION"
        /usr/bin/shasum -a 256 < "$QS_SANDBOX_PROFILE_TEMPLATE" 2>/dev/null || true
        local dir
        for dir in "$QS_PROFILE_SOURCE_DIR" "$QS_CUSTOM_DIR"; do
            [[ -d "$dir" ]] || continue
            (cd "$dir" \
                && find . -type f -print0 | sort -z \
                    | xargs -0 /usr/bin/shasum -a 256 \
                && find . -type f -print0 | sort -z \
                    | xargs -0 /usr/bin/stat -f '%Lp %N') 2>/dev/null || true
        done
    } | /usr/bin/shasum -a 256 | awk '{print $1}'
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
  qs clone     NAME URL_OR_PATH
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
  ~/.config/quicksand/custom/<subsystem>/
                       Host-side personal additions, grouped by subsystem.
                       Synced into the sandbox at build time. Recognised
                       subdirs:
                         profile.d/   .sh scripts run after the canonical
                                      profile.d/ on every session entry
                                      (use 50-99 prefixes to continue from
                                      the 10-49 canonical range)
                         oh-my-zsh/   themes/, plugins/, etc. copied into
                                      the sandbox's ~/.oh-my-zsh/custom/
                                      after install
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
    c|clone)     COMMAND=clone;  needs_name=true  ;;
    b|build)     COMMAND=build;  needs_name=true  ;;
    u|uninstall) COMMAND=uninstall; needs_name=true ;;
    *)           abort "Unknown command: $1 (try: qs --help)" ;;
esac
readonly COMMAND

CLONE_SOURCE=""
if [[ "${needs_name:-false}" == "true" ]]; then
    [[ $# -ge 2 ]] || abort "sandbox name required after '$1' (try: qs --help)"
    validate_sandbox_name "$2"
    SANDBOX_NAME="$2"
    case "$COMMAND" in
        shell|claude) INITIAL_DIR="${3:-}" ;;
        clone)
            [[ $# -ge 3 ]] || abort "qs clone requires URL or local path (try: qs --help)"
            CLONE_SOURCE="$3"
            ;;
    esac
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
# Host-side record of `qs clone` artifacts that outlive the sandbox (GitHub
# deploy keys, `quicksand` remotes on host repos), consumed by uninstall.
# One tab-separated line per clone: REPO_NAME\tOWNER/REPO\tLOCAL_REPO_PATH
# (fields 2 and 3 may be empty).
readonly QS_CLONES_MANIFEST="$INSTALL_DIR/clones-$SANDBOX_NAME"
# Host-side personal additions. The whole tree is rsync'd verbatim into
# the sandbox's _quicksand/custom/. Recognised subdirs:
#   custom/profile.d/   .sh scripts run after canonical (50-99 prefixes)
#   custom/oh-my-zsh/   staged for ~/.oh-my-zsh/custom/ (applied by 46-*)
readonly QS_CUSTOM_DIR="$INSTALL_DIR/custom"
readonly QS_CUSTOM_SANDBOX_DIR="$QS_PRIVATE_DIR/custom"
readonly QS_REPOS_DIR="$SHARED_WORKSPACE/repos"
readonly QS_SSH_DIR="$QS_PRIVATE_DIR/.ssh"
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

# Force a (re)build when the marker is missing or the recorded config
# fingerprint no longer matches the repo (except when uninstalling).
readonly QS_CONFIG_FINGERPRINT="$(config_fingerprint)"
REBUILD_REASON=""
if [[ "$COMMAND" != "uninstall" ]]; then
    if [[ "$REBUILD" == "true" ]]; then
        REBUILD_REASON="rebuild requested"
    elif [[ ! -f "$INSTALL_MARKER" ]]; then
        REBUILD=true
        REBUILD_REASON="not installed yet"
        QS_VERBOSE=$(( QS_VERBOSE > 1 ? QS_VERBOSE : 1 ))
    elif [[ "$(head -n1 "$INSTALL_MARKER" 2>/dev/null)" != "$QS_CONFIG_FINGERPRINT" ]]; then
        REBUILD=true
        REBUILD_REASON="configuration changed since last build"
    fi
fi

if [[ "$NO_BUILD" == "true" ]]; then
    [[ "$COMMAND" != "build" ]]    || abort "refusing build with --no-build set"
    [[ "$COMMAND" != "uninstall" ]] || abort "refusing uninstall with --no-build set"
    [[ "$REBUILD" == "false" ]] \
        || abort "sandbox '$SANDBOX_NAME' needs a build ($REBUILD_REASON) but --no-build is set"
fi
readonly NO_BUILD REBUILD REBUILD_REASON USE_SANDBOX


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

# Best-effort: delete the deploy key with exactly this title from a GitHub
# repo. Never fails the caller — on any problem, points at the repo's key
# settings page so the user can finish by hand.
delete_deploy_key() {
    local owner_repo="$1" title="$2"
    local keys_url="https://github.com/$owner_repo/settings/keys"
    if ! command -v gh &>/dev/null; then
        warn "gh not available — if a deploy key '$title' exists, remove it at $keys_url"
        return 0
    fi
    local listing
    if ! listing="$(gh repo deploy-key list -R "$owner_repo" \
            --json id,title --jq '.[] | [.id, .title] | @tsv' 2>/dev/null)"; then
        warn "Could not list deploy keys for $owner_repo — if '$title' exists, remove it at $keys_url"
        return 0
    fi
    local key_id key_title
    while IFS=$'\t' read -r key_id key_title; do
        [[ "$key_title" == "$title" ]] || continue
        if gh repo deploy-key delete "$key_id" -R "$owner_repo" &>/dev/null; then
            info "Removed deploy key '$title' from $owner_repo"
        else
            warn "Failed to delete deploy key '$title' (id $key_id) from $owner_repo — remove it at $keys_url"
        fi
    done <<< "$listing"
}

# Undo host-side artifacts recorded at clone time: deploy keys registered
# on GitHub and `quicksand` remotes added to host repos.
cleanup_clone_artifacts() {
    [[ -f "$QS_CLONES_MANIFEST" ]] || return 0
    local repo_name owner_repo local_repo remote_url
    while IFS=$'\t' read -r repo_name owner_repo local_repo; do
        [[ -n "$repo_name" ]] || continue
        [[ -z "$owner_repo" ]] \
            || delete_deploy_key "$owner_repo" "qs:$SANDBOX_NAME:$repo_name"
        if [[ -n "$local_repo" && -d "$local_repo" ]]; then
            # Only touch the remote if it still points into this sandbox.
            remote_url="$(git -C "$local_repo" remote get-url quicksand 2>/dev/null || true)"
            if [[ "$remote_url" == "$QS_REPOS_DIR/"* ]]; then
                git -C "$local_repo" remote remove quicksand 2>/dev/null \
                    && info "Removed 'quicksand' remote from $local_repo" \
                    || warn "Could not remove 'quicksand' remote from $local_repo"
            fi
        fi
    done < "$QS_CLONES_MANIFEST"
    rm -f "$QS_CLONES_MANIFEST"
}

uninstall() {
    info "Uninstalling sandbox '$SANDBOX_NAME'..."

    cleanup_clone_artifacts

    # Best-effort: tear down any running session for this sandbox user.
    # `|| true` swallows pipefail-induced ERR when the user is already
    # gone (dscl exits 56 for "no such record").
    local uid
    uid=$(dscl . -read "/Users/$QUICKSAND_USER" UniqueID 2>/dev/null \
        | awk '{print $2}' || true)
    if [[ -n "$uid" ]]; then
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

# Append a clone record to the manifest (see QS_CLONES_MANIFEST) so
# uninstall can clean up after it. Idempotent: skips exact duplicates.
record_clone() {
    local entry
    entry="$(printf '%s\t%s\t%s' "$1" "$2" "$3")"
    mkdir -p "$INSTALL_DIR"
    grep -qxF "$entry" "$QS_CLONES_MANIFEST" 2>/dev/null \
        || echo "$entry" >> "$QS_CLONES_MANIFEST"
}

# Clone a git repo into $QS_REPOS_DIR/<reponame>. For GitHub SSH URLs,
# generates a per-repo ed25519 deploy key and registers it via `gh` (or
# prints it for manual upload). For local-path sources, derives the URL
# from the local repo's origin and adds a `quicksand` remote on the host
# repo pointing at the sandbox copy. Sets CLONE_DEST as a side effect.
do_clone() {
    local source="$CLONE_SOURCE"
    local local_repo="" url

    if [[ -d "$source" ]]; then
        local_repo="$(cd "$source" && pwd -P)"
        url="$(git -C "$local_repo" remote get-url origin 2>/dev/null || true)"
        [[ -n "$url" ]] || abort "Local repo $local_repo has no 'origin' remote — can't clone via network"
    else
        url="$source"
    fi

    # Auto-convert HTTPS GitHub → SSH so deploy-key auth works.
    if [[ "$url" == https://github.com/* ]]; then
        local rest="${url#https://github.com/}"
        rest="${rest%/}"; rest="${rest%.git}"
        if [[ "$rest" =~ ^([^/]+)/([^/]+)$ ]]; then
            url="git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
            debug "Converted to SSH URL: $url"
        fi
    fi

    local repo_name
    repo_name="$(basename "$url" .git)"
    [[ -n "$repo_name" && "$repo_name" != "/" ]] \
        || abort "Could not determine repo name from $url"

    CLONE_DEST="$QS_REPOS_DIR/$repo_name"
    CLONE_LINK="/Users/$QUICKSAND_USER/$repo_name"
    [[ ! -e "$CLONE_DEST" ]] \
        || abort "Destination $CLONE_DEST already exists. Run 'qs uninstall $SANDBOX_NAME' to start over, or use a different sandbox name."
    [[ ! -e "$CLONE_LINK" && ! -L "$CLONE_LINK" ]] \
        || abort "$CLONE_LINK already exists in the sandbox home — rename it or run 'qs uninstall $SANDBOX_NAME'."

    local ssh_cmd="" owner_repo=""
    if [[ "$url" =~ ^git@github\.com:([^/]+)/([^/]+)\.git$ ]]; then
        local owner="${BASH_REMATCH[1]}" gh_repo="${BASH_REMATCH[2]}"
        owner_repo="$owner/$gh_repo"
        local key_path="$QS_SSH_DIR/id_ed25519_$repo_name"
        local pub_path="$key_path.pub"

        mkdir -p "$QS_SSH_DIR"
        chmod 0700 "$QS_SSH_DIR"

        if [[ ! -f "$key_path" ]]; then
            info "Generating deploy key for $owner_repo..."
            ssh-keygen -t ed25519 -f "$key_path" -N "" -q \
                -C "qs-deploy-${repo_name}@$(hostname)"
        fi
        chmod 0600 "$key_path"

        ssh_cmd="ssh -i $key_path -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

        local uploaded=false
        if command -v gh &>/dev/null; then
            info "Registering deploy key with $owner_repo (write access)..."
            if gh repo deploy-key add "$pub_path" -R "$owner_repo" \
                    --title "qs:$SANDBOX_NAME:$repo_name" --allow-write &>/dev/null; then
                uploaded=true
            else
                warn "gh repo deploy-key add failed — gh may not be authenticated, you may lack admin on the repo, or a key with this title already exists."
            fi
        fi

        if [[ "$uploaded" == "false" ]]; then
            echo
            echo "Add this public key as a deploy key (with write access) at:"
            echo "  https://github.com/$owner_repo/settings/keys/new"
            echo
            cat "$pub_path"
            echo
            if [[ -t 0 ]]; then
                read -r -p "Press Enter once added, or Ctrl-C to abort... " _
            fi
        fi
    else
        debug "Non-GitHub URL; skipping deploy-key generation"
    fi

    # Recorded before the clone so a failed clone still leaves a manifest
    # entry covering the deploy key registered above.
    record_clone "$repo_name" "$owner_repo" "$local_repo"

    info "Cloning $url → $CLONE_DEST"
    mkdir -p "$QS_REPOS_DIR"
    if [[ -n "$ssh_cmd" ]]; then
        GIT_SSH_COMMAND="$ssh_cmd" git clone "$url" "$CLONE_DEST"
        git -C "$CLONE_DEST" config core.sshCommand "$ssh_cmd"
    else
        git clone "$url" "$CLONE_DEST"
    fi

    if [[ -n "$local_repo" ]]; then
        if git -C "$local_repo" remote | grep -qx quicksand; then
            git -C "$local_repo" remote set-url quicksand "$CLONE_DEST"
        else
            git -C "$local_repo" remote add quicksand "$CLONE_DEST"
        fi
        info "Added 'quicksand' remote on $local_repo → $CLONE_DEST"
    fi

    # Symlink the clone into the sandbox user's home so the in-sandbox
    # path is short (~/repo). /Users/$QUICKSAND_USER is sandbox-owned
    # 0750, so we create the link as the sandbox user via the existing
    # NOPASSWD env entry.
    sudo --user="$QUICKSAND_USER" /usr/bin/env ln -sfn "$CLONE_DEST" "$CLONE_LINK"
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
    info "Building sandbox '$SANDBOX_NAME'...${REBUILD_REASON:+ ($REBUILD_REASON)}"

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

    # Sandbox profile — render from config/sandbox.sb template into
    # /var/quicksand/sandbox-qs-NAME.sb with per-sandbox paths substituted.
    debug "Writing sandbox profile"
    [[ -f "$QS_SANDBOX_PROFILE_TEMPLATE" ]] \
        || abort "Sandbox profile template missing at $QS_SANDBOX_PROFILE_TEMPLATE"

    # The boot volume's /Volumes entry must survive the profile's
    # /Volumes deny, and the volume can be renamed or localized.
    # A name with a double quote would corrupt the rendered profile;
    # fall back to the stock name rather than break sandbox-exec.
    BOOT_VOLUME="$(diskutil info -plist / 2>/dev/null \
        | plutil -extract VolumeName raw - 2>/dev/null || true)"
    if [[ -z "$BOOT_VOLUME" || "$BOOT_VOLUME" == *'"'* ]]; then
        warn "Could not determine boot volume name; assuming 'Macintosh HD'"
        BOOT_VOLUME="Macintosh HD"
    fi
    # Escape sed-replacement metacharacters (\ & and the | delimiter).
    BOOT_VOLUME_SED="$(printf '%s' "$BOOT_VOLUME" | sed -e 's/[\\&|]/\\&/g')"

    sudo mkdir -p "$(dirname "$SANDBOX_PROFILE")"
    sudo /bin/chmod 0755 "$(dirname "$SANDBOX_PROFILE")"
    sed -e "s|@SHARED_WORKSPACE@|$SHARED_WORKSPACE|g" \
        -e "s|@QUICKSAND_USER_HOME@|/Users/$QUICKSAND_USER|g" \
        -e "s|@BOOT_VOLUME@|$BOOT_VOLUME_SED|g" \
        "$QS_SANDBOX_PROFILE_TEMPLATE" \
        | sudo tee "$SANDBOX_PROFILE" > /dev/null
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

    if [[ -d "$QS_CUSTOM_DIR" ]]; then
        debug "Syncing $QS_CUSTOM_DIR/ → $QS_CUSTOM_SANDBOX_DIR/"
        mkdir -p "$QS_CUSTOM_SANDBOX_DIR"
        /usr/bin/rsync \
            --checksum --recursive --perms --times \
            "$QS_CUSTOM_DIR/" "$QS_CUSTOM_SANDBOX_DIR/"
    fi

    # First line: config fingerprint (compared on every run); second:
    # build time, for humans.
    mkdir -p "$INSTALL_DIR"
    { echo "$QS_CONFIG_FINGERPRINT"; date; } > "$INSTALL_MARKER"
fi

if [[ "$COMMAND" == "build" ]]; then
    info "Sandbox '$SANDBOX_NAME' ready."
    exit 0
fi

if [[ "$COMMAND" == "clone" ]]; then
    (( ${#COMMAND_ARGS[@]} == 0 )) \
        || abort "qs clone doesn't accept '--' args; clone returns to the host shell"
    do_clone
    info ""
    info "Cloned to:    $CLONE_DEST"
    info "Sandbox path: $CLONE_LINK (symlink)"
    info ""
    info "Enter the sandbox with:"
    info "  qs shell  $SANDBOX_NAME $CLONE_LINK"
    info "  qs claude $SANDBOX_NAME $CLONE_LINK"
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

# Run per-session profile scripts as the sandbox user.
ZSH_COMMAND="$ZSH_COMMAND; setopt null_glob; for s in $SHARED_WORKSPACE/_quicksand/profile.d/*.sh $SHARED_WORKSPACE/_quicksand/custom/profile.d/*.sh; do [[ -f \"\$s\" && -x \"\$s\" ]] && \"\$s\"; done"

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
# Locale: `env -i` below would otherwise leave the sandbox in the C
# locale, degrading multibyte line editing in zsh and UTF-8 handling
# in git and python.
[[ -n "${LANG:-}" ]]   && EXTRA_ENV+=("LANG=$LANG")
[[ -n "${LC_ALL:-}" ]] && EXTRA_ENV+=("LC_ALL=$LC_ALL")

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
exec sudo --set-home --user="$QUICKSAND_USER" \
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
