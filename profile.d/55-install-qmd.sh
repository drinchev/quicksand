#!/bin/bash
# Install qmd (https://github.com/tobi/qmd) — a local markdown search engine
# used as shared memory between agent sessions in this sandbox (see
# 56-setup-qmd.sh for the collections it indexes).
#
# qmd needs Node >= 22, which only exists via pnpm (46-install-pnpm.sh
# provisions Node 24 into $PNPM_HOME/bin) — hence the ordering after 46 and
# the wrapper below: profile.d scripts and `env -i` launches run with the
# base sandbox PATH, where node is NOT resolvable, so a bare symlink to the
# pnpm-installed bin would break outside zshrc-sourced shells.
#
# Idempotent: no-op once the wrapper is in place.
set -Eeuo pipefail

[[ -x "$HOME/.local/bin/qmd" ]] && exit 0

# Same locator as 46-install-pnpm.sh: pnpm >= 10 installs the CLI at
# $PNPM_HOME/bin/pnpm; older standalone installers used $PNPM_HOME/pnpm.
find_pnpm() {
    command -v pnpm 2>/dev/null && return 0
    local p
    for p in "$HOME/Library/pnpm/bin/pnpm" "$HOME/Library/pnpm/pnpm" \
             "$HOME/.local/share/pnpm/pnpm" "$HOME/.pnpm/pnpm"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

PNPM="$(find_pnpm || true)"
if [[ -z "$PNPM" ]]; then
    echo "qmd install skipped: pnpm not found (46-install-pnpm.sh failed?)" >&2
    exit 0
fi

export PNPM_HOME="$HOME/Library/pnpm"
export PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH"

echo "Installing qmd into sandbox..." >&2
# pnpm >= 10 blocks dependency build scripts by default: skipped silently
# without a TTY (qmd then dies at first use on better-sqlite3's missing
# bindings), or via an interactive "choose which packages to build" prompt
# in a terminal, which would hang session startup. Allow all builds instead
# of allowlisting per package — the dep list changes across qmd releases
# (better-sqlite3, node-llama-cpp, tree-sitter-*), and running postinstall
# scripts of a package we install anyway is what the sandbox is for.
"$PNPM" add -g --dangerously-allow-all-builds @tobilu/qmd

# pnpm's global bin dir is $PNPM_HOME ($PNPM_HOME/bin on some versions).
QMD_BIN=""
for c in "$PNPM_HOME/qmd" "$PNPM_HOME/bin/qmd"; do
    [[ -x "$c" ]] && { QMD_BIN="$c"; break; }
done
[[ -n "$QMD_BIN" ]] || { echo "qmd not found under $PNPM_HOME after install" >&2; exit 1; }

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/qmd" <<EOF
#!/bin/bash
# quicksand wrapper: expose the pnpm-provisioned node to qmd regardless of
# how the calling shell was launched (managed by 55-install-qmd.sh).
export PNPM_HOME="\$HOME/Library/pnpm"
export PATH="\$PNPM_HOME/bin:\$PNPM_HOME:\$PATH"
exec "$QMD_BIN" "\$@"
EOF
chmod +x "$HOME/.local/bin/qmd"
