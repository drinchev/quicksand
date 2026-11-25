#!/bin/bash
# Build Quicksand.app, install it, and put its qs command on your PATH.
#
#   app/scripts/install.sh              # build, install to ~/Applications, link /usr/local/bin/qs, open
#   app/scripts/install.sh --dev        # link the debug build instead (finds qs.bash in this checkout)
#
# Options:
#   --dest DIR      install the app into DIR (default: ~/Applications)
#   --link PATH     where to put the qs link (default: /usr/local/bin/qs)
#   --no-build      install the app already built at app/build/Quicksand.app
#   --no-open       don't start the app afterwards
#   --dev           build and link app/.build/debug/qs; no app install
#   --              pass the remaining arguments to `swift build`
#
# Run it on the host, not inside a sandbox: the app is a host program. The
# link needs sudo when its directory isn't writable by you; sudo asks for
# your password. An existing file at the link path is only replaced when
# it is a link to a qs (another Quicksand.app or a debug build), never
# anything else.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications"
LINK="/usr/local/bin/qs"
BUILD=true OPEN=true DEV=false
SWIFT_ARGS=()

die()  { echo "install: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while (($#)); do
    case "$1" in
        --dest) [[ $# -ge 2 ]] || die "--dest needs a directory"; DEST="$2"; shift 2 ;;
        --link) [[ $# -ge 2 ]] || die "--link needs a path"; LINK="$2"; shift 2 ;;
        --no-build) BUILD=false; shift ;;
        --no-open) OPEN=false; shift ;;
        --dev) DEV=true; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --) shift; SWIFT_ARGS=("$@"); break ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[[ -z "${QS_SESSION_ID:-}" ]] || die "run this on the host, not inside a quicksand sandbox"

# link_qs TARGET — point $LINK at TARGET, with sudo only when needed.
link_qs() {
    local target="$1" dir current
    dir="$(dirname "$LINK")"
    if [[ -L "$LINK" ]]; then
        current="$(readlink "$LINK")"
        if [[ "$current" == "$target" ]]; then
            info "$LINK already points at $target"
            return 0
        fi
        [[ "$current" == */qs ]] || die "$LINK is a link to $current, not to a qs — remove it yourself if you want it replaced"
    elif [[ -e "$LINK" ]]; then
        die "$LINK exists and isn't a link — remove it yourself if you want it replaced"
    fi

    local sudo=()
    if ! { [[ -d "$dir" && -w "$dir" ]] || { [[ ! -e "$dir" ]] && mkdir -p "$dir" 2>/dev/null; }; }; then
        sudo=(sudo)
        info "Linking $LINK needs admin rights (sudo)"
    fi
    "${sudo[@]+"${sudo[@]}"}" mkdir -p "$dir"
    "${sudo[@]+"${sudo[@]}"}" ln -sfn "$target" "$LINK"
    info "Linked $LINK -> $target"
}

if $DEV; then
    info "Building the debug qs"
    swift build --package-path "$APP_DIR" --product qs "${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"}"
    bin="$(swift build --package-path "$APP_DIR" --show-bin-path "${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"}")"
    link_qs "$bin/qs"
else
    BUILT="$APP_DIR/build/Quicksand.app"
    if $BUILD; then
        info "Building Quicksand.app"
        "$APP_DIR/scripts/bundle.sh" "${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"}"
    fi
    [[ -x "$BUILT/Contents/MacOS/qs" ]] || die "no app at $BUILT — build it first (drop --no-build)"

    INSTALLED="$DEST/Quicksand.app"
    # Replacing a running app's files under it breaks it; quit it first.
    was_running=false
    if pgrep -f "$INSTALLED/Contents/MacOS/Quicksand" >/dev/null 2>&1; then
        was_running=true
        info "Quitting the running Quicksand.app"
        osascript -e 'quit app id "com.quicksand.app"' >/dev/null 2>&1 || true
        for _ in $(seq 1 50); do
            pgrep -f "$INSTALLED/Contents/MacOS/Quicksand" >/dev/null 2>&1 || break
            sleep 0.1
        done
        pkill -f "$INSTALLED/Contents/MacOS/Quicksand" 2>/dev/null || true
    fi

    info "Installing to $INSTALLED"
    mkdir -p "$DEST"
    rm -rf "$INSTALLED"
    cp -R "$BUILT" "$INSTALLED"

    link_qs "$INSTALLED/Contents/MacOS/qs"

    if $OPEN || $was_running; then
        info "Opening Quicksand.app"
        open "$INSTALLED" || echo "install: couldn't open $INSTALLED — open it from Finder" >&2
    fi
fi

# What the user's shell will run as `qs`.
case ":$PATH:" in
    *":$(dirname "$LINK"):"*) ;;
    *) echo "install: $(dirname "$LINK") isn't on your PATH — add it, e.g.: echo 'export PATH=\"$(dirname "$LINK"):\$PATH\"' >> ~/.zshrc" >&2 ;;
esac
if grep -Eqs '^[[:space:]]*alias[[:space:]]+qs=' "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.zprofile" 2>/dev/null; then
    echo "install: an 'alias qs=...' in your shell config overrides the link — delete that line, then run: unalias qs" >&2
fi
info "Done: $("$LINK" --version)"
