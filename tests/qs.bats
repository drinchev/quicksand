#!/usr/bin/env bats
# Unit tests for qs. Each test sources a private copy of the repo (so
# fingerprint tests can mutate profile.d/ etc.) and calls functions
# directly with controlled globals; external commands are stubbed via
# PATH where needed. Nothing here touches sudo or real sandboxes.

setup() {
    # qs refuses to load inside a quicksand session (its nested-sandbox
    # guard); drop the marker so the suite runs in a sandbox too — where
    # agents develop quicksand itself.
    unset QS_SESSION_ID
    REPO_COPY="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO_COPY"
    cp "$BATS_TEST_DIRNAME/../qs" "$REPO_COPY/qs"
    cp -R "$BATS_TEST_DIRNAME/../profile.d" "$REPO_COPY/profile.d"
    cp -R "$BATS_TEST_DIRNAME/../logout.d" "$REPO_COPY/logout.d"
    cp -R "$BATS_TEST_DIRNAME/../config" "$REPO_COPY/config"
    cp -R "$BATS_TEST_DIRNAME/../libexec" "$REPO_COPY/libexec"
    QS="$REPO_COPY/qs"
    STUBS="$BATS_TEST_TMPDIR/stubs"
    STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$STUBS"
    # REPO_COPY is exported so provider-test helpers can exec/source
    # "$REPO_COPY/libexec/qs-auth-*" from `run bash -c` subshells.
    export QS REPO_COPY STUBS STUB_LOG
}

# make_stub NAME SCRIPT-BODY — create an executable stub on $STUBS.
make_stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$STUBS/$1"
    chmod +x "$STUBS/$1"
}

# Run a bash snippet with qs sourced (main is guarded against sourcing).
qs_run() {
    run bash -c "source \"\$QS\"; $1"
}


###############################################################################
# CLI smoke (executed, not sourced)
###############################################################################

@test "qs --help exits 0 and prints usage" {
    run "$QS" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "qs --version prints the version" {
    run "$QS" --version
    [ "$status" -eq 0 ]
    [[ "$output" == "qs version "* ]]
}

@test "unknown command fails" {
    run "$QS" frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown command: frobnicate"* ]]
}

@test "unknown option fails" {
    run "$QS" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option: --bogus"* ]]
}

@test "sourcing qs does not execute main" {
    qs_run 'type cmd_launch >/dev/null && echo sourced-ok'
    [ "$status" -eq 0 ]
    [[ "$output" == "sourced-ok" ]]
}


###############################################################################
# cmd_list (fixture roots via the QS_LIST_* test seams)
###############################################################################

@test "cmd_list shows each sandbox's clones and memory repo" {
    mkdir -p "$BATS_TEST_TMPDIR/homes/qs-work" \
             "$BATS_TEST_TMPDIR/homes/qs-toy" \
             "$BATS_TEST_TMPDIR/shared/qs-work/repos/proj" \
             "$BATS_TEST_TMPDIR/shared/qs-work/repos/tools" \
             "$BATS_TEST_TMPDIR/shared/qs-work/memory/.git" \
             "$BATS_TEST_TMPDIR/fakehome/.config/quicksand"
    printf 'proj\tme/proj\t\n'  > "$BATS_TEST_TMPDIR/fakehome/.config/quicksand/clones-work"
    printf 'tools\t\t/l/tools\n' >> "$BATS_TEST_TMPDIR/fakehome/.config/quicksand/clones-work"
    printf 'agent-memory\tme/agent-memory\t\n' \
        > "$BATS_TEST_TMPDIR/fakehome/.config/quicksand/memory-work"
    qs_run 'HOME="$BATS_TEST_TMPDIR/fakehome"
            QS_LIST_HOMES_DIR="$BATS_TEST_TMPDIR/homes"
            QS_LIST_SHARED_DIR="$BATS_TEST_TMPDIR/shared"
            cmd_list'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "Sandboxes:" ]
    [ "${lines[1]}" == "  toy" ]
    [ "${lines[2]}" == "  work" ]
    [ "${lines[3]}" == "    proj (me/proj)" ]
    [ "${lines[4]}" == "    tools" ]
    [ "${lines[5]}" == "    memory (me/agent-memory)" ]
}

@test "cmd_list survives a missing workspace and manifests" {
    mkdir -p "$BATS_TEST_TMPDIR/homes/qs-bare" "$BATS_TEST_TMPDIR/shared" \
             "$BATS_TEST_TMPDIR/fakehome"
    qs_run 'HOME="$BATS_TEST_TMPDIR/fakehome"
            QS_LIST_HOMES_DIR="$BATS_TEST_TMPDIR/homes"
            QS_LIST_SHARED_DIR="$BATS_TEST_TMPDIR/shared"
            cmd_list'
    [ "$status" -eq 0 ]
    [ "${lines[1]}" == "  bare" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "cmd_list prints the none hint when no sandboxes exist" {
    mkdir -p "$BATS_TEST_TMPDIR/homes"
    qs_run 'QS_LIST_HOMES_DIR="$BATS_TEST_TMPDIR/homes"
            QS_LIST_SHARED_DIR="$BATS_TEST_TMPDIR/shared"
            cmd_list'
    [ "$status" -eq 0 ]
    [[ "$output" == *"(none — run 'qs build <NAME>')"* ]]
}


###############################################################################
# validate_sandbox_name
###############################################################################

@test "validate_sandbox_name accepts letters, digits, - and _" {
    qs_run 'validate_sandbox_name "Abc-12_3" && echo ok'
    [ "$status" -eq 0 ]
    [[ "$output" == "ok" ]]
}

@test "validate_sandbox_name rejects invalid characters" {
    qs_run 'validate_sandbox_name "bad name!"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"must contain only"* ]]
}

@test "validate_sandbox_name rejects overlong names" {
    qs_run 'validate_sandbox_name "aaaaaaaaaaaaaaaaa"'  # 17 chars
    [ "$status" -eq 1 ]
    [[ "$output" == *"characters or fewer"* ]]
}


###############################################################################
# quote_zsh_args
###############################################################################

@test "quote_zsh_args round-trips spaces, quotes and dollar signs" {
    qs_run 'q=$(quote_zsh_args "a b" "\$HOME" "it'\''s" "\"x\"");
            /bin/zsh -fc "for a in $q; do print -r -- \$a; done"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "a b" ]
    [ "${lines[1]}" == '$HOME' ]
    [ "${lines[2]}" == "it's" ]
    [ "${lines[3]}" == '"x"' ]
}


###############################################################################
# build_session_command (in-sandbox zsh command assembly)
###############################################################################

@test "build_session_command assembles TMPDIR, cd, hooks and the logout trap" {
    qs_run 'QUICKSAND_USER=qs-demo SHARED_WORKSPACE=/ws INITIAL_DIR=/ws/repos/proj
            COMMAND=shell COMMAND_ARGS=()
            build_session_command true; printf "%s" "$ZSH_COMMAND"'
    [ "$status" -eq 0 ]
    [[ "$output" == "export TMPDIR="* ]]
    [[ "$output" == *"cd /ws/repos/proj "* ]]
    [[ "$output" == *"2>/dev/null || cd ~"* ]]
    [[ "$output" == *"setopt null_glob"* ]]
    [[ "$output" == *"/ws/_quicksand/profile.d/*.sh /ws/_quicksand/custom/profile.d/*.sh"* ]]
    [[ "$output" == *"trap 'for s in /ws/_quicksand/logout.d/*.sh"*"' EXIT"* ]]
}

@test "build_session_command claude: bypass flag, zshrc source, tab label" {
    qs_run 'QUICKSAND_USER=qs-demo SHARED_WORKSPACE=/ws INITIAL_DIR=
            COMMAND=claude COMMAND_ARGS=(--resume abc)
            build_session_command true
            printf "%s\n%s" "$QS_SESSION_KIND" "$ZSH_COMMAND"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "Claude" ]
    [[ "$output" == *"cd /Users/qs-demo "* ]]
    [[ "$output" == *"[[ -r ~/.zshrc ]] && source ~/.zshrc; claude --dangerously-skip-permissions --resume abc"* ]]
}

@test "build_session_command one-off command: quoted payload, no tab label" {
    qs_run 'QUICKSAND_USER=qs-demo SHARED_WORKSPACE=/ws INITIAL_DIR=
            COMMAND=shell COMMAND_ARGS=(echo "a b")
            build_session_command true
            printf "[%s]\n%s" "$QS_SESSION_KIND" "$ZSH_COMMAND"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "[]" ]
    [[ "$output" == *"source ~/.zshrc; echo a\\ b"* ]]
}

@test "build_session_command interactive shell: zsh -i, Shell label, no zshrc double-source" {
    qs_run 'QUICKSAND_USER=qs-demo SHARED_WORKSPACE=/ws INITIAL_DIR=
            COMMAND=shell COMMAND_ARGS=()
            build_session_command true
            printf "%s\n%s" "$QS_SESSION_KIND" "$ZSH_COMMAND"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "Shell" ]
    [[ "$output" == *"; /bin/zsh -i" ]]
    [[ "$output" != *"source ~/.zshrc"* ]]
}

@test "build_session_command piped stdin: plain zsh with zshrc sourced, no label" {
    qs_run 'QUICKSAND_USER=qs-demo SHARED_WORKSPACE=/ws INITIAL_DIR=
            COMMAND=shell COMMAND_ARGS=()
            build_session_command false
            printf "[%s]\n%s" "$QS_SESSION_KIND" "$ZSH_COMMAND"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "[]" ]
    [[ "$output" == *"source ~/.zshrc; /bin/zsh" ]]
}

# The end-to-end check for all three quoting layers: actually run the
# assembled command in zsh, with hooks and the initial dir under the test
# tmpdir. HOME is overridden so no real ~/.zshrc is sourced.
@test "assembled session command runs hooks, cds, round-trips args, fires the exit trap" {
    mkdir -p "$BATS_TEST_TMPDIR/ws/_quicksand/profile.d" \
             "$BATS_TEST_TMPDIR/ws/_quicksand/logout.d" \
             "$BATS_TEST_TMPDIR/start dir"
    printf '#!/bin/bash\necho profile-ran >> "%s"\n' "$STUB_LOG" \
        > "$BATS_TEST_TMPDIR/ws/_quicksand/profile.d/10-t.sh"
    printf '#!/bin/bash\necho logout-ran >> "%s"\n' "$STUB_LOG" \
        > "$BATS_TEST_TMPDIR/ws/_quicksand/logout.d/10-t.sh"
    chmod +x "$BATS_TEST_TMPDIR/ws/_quicksand/profile.d/10-t.sh" \
             "$BATS_TEST_TMPDIR/ws/_quicksand/logout.d/10-t.sh"
    # The tricky characters ride as an argv element — the assembly's
    # guarantee is that COMMAND_ARGS survive exactly one zsh re-parse and
    # arrive verbatim as arguments, not that they survive being spliced
    # into yet another nested shell script.
    qs_run 'QUICKSAND_USER=qs-demo
            SHARED_WORKSPACE="$BATS_TEST_TMPDIR/ws"
            INITIAL_DIR="$BATS_TEST_TMPDIR/start dir"
            COMMAND=shell
            COMMAND_ARGS=(/bin/sh -c "pwd; printf \"%s\n\" \"\$1\"" sh "it'\''s a b\$c")
            build_session_command false
            HOME="$BATS_TEST_TMPDIR" /bin/zsh -c "$ZSH_COMMAND"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"/start dir"* ]]
    [[ "$output" == *"it's a b\$c"* ]]
    grep -q profile-ran "$STUB_LOG"
    grep -q logout-ran "$STUB_LOG"
}


###############################################################################
# next_free_id (dscl stubbed)
###############################################################################

@test "next_free_id picks the first gap across users and groups" {
    make_stub dscl 'case "$3" in
        /Users)  printf "u1 600\nu2 601\n" ;;
        /Groups) printf "g1 603\n" ;;
    esac'
    qs_run 'PATH="$STUBS:$PATH"; next_free_id'
    [ "$status" -eq 0 ]
    [ "$output" == "602" ]
}

@test "next_free_id starts at QS_MIN_ID when nothing is taken" {
    make_stub dscl ':'
    qs_run 'PATH="$STUBS:$PATH"; next_free_id'
    [ "$status" -eq 0 ]
    [ "$output" == "600" ]
}

@test "next_free_id respects a QS_MIN_ID override" {
    make_stub dscl 'case "$3" in
        /Users) printf "u1 700\n" ;;
        *) : ;;
    esac'
    qs_run 'PATH="$STUBS:$PATH"; QS_MIN_ID=700 next_free_id'
    [ "$status" -eq 0 ]
    [ "$output" == "701" ]
}


###############################################################################
# config_fingerprint
###############################################################################

@test "config_fingerprint is deterministic" {
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint; config_fingerprint'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "${lines[1]}" ]
    [ "${#lines[0]}" -eq 64 ]
}

@test "config_fingerprint changes when a profile script changes" {
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    local before="$output"
    echo "# tweak" >> "$REPO_COPY/profile.d/10-keychain.sh"
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    [ "$output" != "$before" ]
}

@test "config_fingerprint changes when an exec bit flips" {
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    local before="$output"
    chmod -x "$REPO_COPY/profile.d/10-keychain.sh"
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    [ "$output" != "$before" ]
}

@test "config_fingerprint changes when quicksand.md changes" {
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    local before="$output"
    echo "tweak" >> "$REPO_COPY/config/quicksand.md"
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    [ "$output" != "$before" ]
}

@test "config_fingerprint changes when the Claude settings template changes" {
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    local before="$output"
    echo '{"cleanupPeriodDays":1}' > "$REPO_COPY/config/claude-settings.json"
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    [ "$output" != "$before" ]
}

@test "config_fingerprint changes when the speech broker changes" {
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    local before="$output"
    echo "# tweak" >> "$REPO_COPY/config/qs-say-broker"
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    [ "$output" != "$before" ]
}

@test "config_fingerprint changes when the sandbox profile template changes" {
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    local before="$output"
    echo ";; tweak" >> "$REPO_COPY/config/sandbox.sb"
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    [ "$output" != "$before" ]
}

@test "config_fingerprint sees the custom overlay" {
    local custom="$BATS_TEST_TMPDIR/custom"
    mkdir -p "$custom/profile.d"
    export CUSTOM_DIR="$custom"
    qs_run 'QS_CUSTOM_DIR="$CUSTOM_DIR"; config_fingerprint'
    local before="$output"
    echo "echo hi" > "$custom/profile.d/50-me.sh"
    qs_run 'QS_CUSTOM_DIR="$CUSTOM_DIR"; config_fingerprint'
    [ "$output" != "$before" ]
}


###############################################################################
# Clone manifest: record_clone / cleanup_clone_artifacts / delete_deploy_key
###############################################################################

@test "record_clone appends and deduplicates" {
    export MANIFEST="$BATS_TEST_TMPDIR/manifest"
    qs_run 'INSTALL_DIR="$BATS_TEST_TMPDIR"; QS_CLONES_MANIFEST="$MANIFEST"
            record_clone repo owner/repo /some/path
            record_clone repo owner/repo /some/path
            record_clone other "" ""
            cat "$MANIFEST"'
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" == "$(printf 'repo\towner/repo\t/some/path')" ]
}

@test "cleanup deletes only the deploy key with the matching title" {
    make_stub gh 'case "$1 $2 $3" in
        "repo deploy-key list")
            printf "101\tqs:demo:repo\n102\tunrelated-key\n" ;;
        "repo deploy-key delete")
            echo "DELETE $4 $5 $6" >> "$STUB_LOG" ;;
    esac'
    export MANIFEST="$BATS_TEST_TMPDIR/manifest"
    printf 'repo\towner/repo\t\n' > "$MANIFEST"
    qs_run 'PATH="$STUBS:$PATH"; SANDBOX_NAME=demo
            QS_CLONES_MANIFEST="$MANIFEST" QS_REPOS_DIR=/nonexistent/repos
            cleanup_clone_artifacts'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed deploy key 'qs:demo:repo' from owner/repo"* ]]
    grep -q "DELETE 101 -R owner/repo" "$STUB_LOG"
    ! grep -q "DELETE 102" "$STUB_LOG"
    [ ! -f "$MANIFEST" ]
}

@test "cleanup removes a quicksand remote pointing into the sandbox" {
    export HOST_REPO="$BATS_TEST_TMPDIR/hostrepo"
    git -C "$BATS_TEST_TMPDIR" init -q hostrepo
    git -C "$HOST_REPO" remote add quicksand "$BATS_TEST_TMPDIR/ws/repos/repo"
    export MANIFEST="$BATS_TEST_TMPDIR/manifest"
    printf 'repo\t\t%s\n' "$HOST_REPO" > "$MANIFEST"
    qs_run 'SANDBOX_NAME=demo QS_CLONES_MANIFEST="$MANIFEST"
            QS_REPOS_DIR="$BATS_TEST_TMPDIR/ws/repos"
            cleanup_clone_artifacts'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removed 'quicksand' remote"* ]]
    run git -C "$HOST_REPO" remote
    [[ "$output" != *"quicksand"* ]]
}

@test "cleanup leaves a foreign quicksand remote alone" {
    export HOST_REPO="$BATS_TEST_TMPDIR/hostrepo"
    git -C "$BATS_TEST_TMPDIR" init -q hostrepo
    git -C "$HOST_REPO" remote add quicksand /somewhere/else
    export MANIFEST="$BATS_TEST_TMPDIR/manifest"
    printf 'repo\t\t%s\n' "$HOST_REPO" > "$MANIFEST"
    qs_run 'SANDBOX_NAME=demo QS_CLONES_MANIFEST="$MANIFEST"
            QS_REPOS_DIR="$BATS_TEST_TMPDIR/ws/repos"
            cleanup_clone_artifacts'
    [ "$status" -eq 0 ]
    run git -C "$HOST_REPO" remote get-url quicksand
    [ "$output" == "/somewhere/else" ]
}

@test "delete_deploy_key warns and succeeds when gh is missing" {
    qs_run 'PATH=/usr/bin:/bin; delete_deploy_key owner/repo "qs:x:repo"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"gh not available"* ]]
    [[ "$output" == *"https://github.com/owner/repo/settings/keys"* ]]
}


###############################################################################
# parse_args
###############################################################################

@test "parse_args resolves command and name" {
    qs_run 'parse_args shell foo; echo "$COMMAND $SANDBOX_NAME"'
    [ "$status" -eq 0 ]
    [ "$output" == "shell foo" ]
}

@test "parse_args resolves single-letter aliases" {
    qs_run 'parse_args cl foo; echo "$COMMAND"'
    [ "$output" == "claude" ]
    qs_run 'parse_args b foo; echo "$COMMAND"'
    [ "$output" == "build" ]
    qs_run 'parse_args l; echo "$COMMAND"'
    [ "$output" == "list" ]
}

@test "parse_args collects everything after -- into COMMAND_ARGS" {
    qs_run 'parse_args shell foo -- echo "a b" -x
            printf "%s\n" "${COMMAND_ARGS[@]}"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "echo" ]
    [ "${lines[1]}" == "a b" ]
    [ "${lines[2]}" == "-x" ]
}

@test "parse_args sets option flags" {
    qs_run 'parse_args -r -n -x shell foo; echo "$REBUILD $NO_BUILD $USE_SANDBOX"'
    [ "$output" == "true true false" ]
}

@test "parse_args sets OP_WRITE for --write" {
    qs_run 'parse_args --write op-auth foo; echo "$OP_WRITE"'
    [ "$output" == "true" ]
}

@test "parse_args prepends QUICKSAND_ARGS" {
    QUICKSAND_ARGS="-x" qs_run 'parse_args shell foo; echo "$USE_SANDBOX"'
    [ "$output" == "false" ]
}

@test "parse_args QUICKSAND_ARGS preserves quoted args with spaces" {
    QUICKSAND_ARGS='-x shell foo -- run "a b"' qs_run 'parse_args
            echo "$COMMAND $SANDBOX_NAME $USE_SANDBOX"
            printf "%s\n" "${COMMAND_ARGS[@]}"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "shell foo false" ]
    [ "${lines[1]}" == "run" ]
    [ "${lines[2]}" == "a b" ]
}

@test "parse_args requires a name for name-taking commands" {
    qs_run 'parse_args shell'
    [ "$status" -eq 1 ]
    [[ "$output" == *"sandbox name required"* ]]
}

@test "parse_args requires a source for clone" {
    qs_run 'parse_args clone foo'
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires URL or local path"* ]]
}


###############################################################################
# INITIAL_DIR translation (via derive_constants)
###############################################################################

@test "relative PATH resolves against the sandbox home" {
    qs_run 'parse_args shell relpathtest metadata
            derive_constants
            echo "$INITIAL_DIR"'
    [ "$status" -eq 0 ]
    [ "$output" == "/Users/qs-relpathtest/metadata" ]
}

@test "tilde PATH resolves against the sandbox home" {
    qs_run 'parse_args shell relpathtest "~/sub/dir"
            derive_constants
            echo "$INITIAL_DIR"'
    [ "$status" -eq 0 ]
    [ "$output" == "/Users/qs-relpathtest/sub/dir" ]
}

@test "absolute PATH is kept as-is" {
    qs_run 'parse_args shell relpathtest /Users
            derive_constants
            echo "$INITIAL_DIR"'
    [ "$status" -eq 0 ]
    [ "$output" == "/Users" ]
}


###############################################################################
# do_clone (git/gh/ssh-keygen/sudo stubbed)
###############################################################################

@test "do_clone converts HTTPS GitHub URLs to SSH and records the manifest" {
    make_stub git 'echo "git $*" >> "$STUB_LOG"
        [[ "$1" == "clone" ]] && mkdir -p "$3"
        exit 0'
    make_stub gh 'echo "gh $*" >> "$STUB_LOG"; exit 0'
    make_stub ssh-keygen 'while [[ $# -gt 0 ]]; do
            [[ "$1" == "-f" ]] && keyfile="$2"
            shift
        done
        touch "$keyfile" "$keyfile.pub"'
    make_stub sudo 'echo "sudo $*" >> "$STUB_LOG"; exit 0'

    export MANIFEST="$BATS_TEST_TMPDIR/manifest"
    qs_run 'PATH="$STUBS:$PATH"
            CLONE_SOURCE="https://github.com/me/proj"
            SANDBOX_NAME=demo QUICKSAND_USER=qs-bats-nonexistent
            QS_REPOS_DIR="$BATS_TEST_TMPDIR/ws/repos"
            QS_SSH_DIR="$BATS_TEST_TMPDIR/ws/.ssh"
            INSTALL_DIR="$BATS_TEST_TMPDIR" QS_CLONES_MANIFEST="$MANIFEST"
            QS_PRIVATE_DIR="$BATS_TEST_TMPDIR/ws/_quicksand"
            do_clone'
    [ "$status" -eq 0 ]
    grep -q "git clone git@github.com:me/proj.git" "$STUB_LOG"
    grep -q "deploy-key add" "$STUB_LOG"
    grep -q "$(printf 'proj\tme/proj\t')" "$MANIFEST"
}

@test "do_clone honors CLONE_DEST_OVERRIDE and CLONE_KEY_NAME" {
    make_stub git 'echo "git $*" >> "$STUB_LOG"
        [[ "$1" == "clone" ]] && mkdir -p "$3"
        exit 0'
    make_stub gh 'echo "gh $*" >> "$STUB_LOG"; exit 0'
    make_stub ssh-keygen 'while [[ $# -gt 0 ]]; do
            [[ "$1" == "-f" ]] && keyfile="$2"
            shift
        done
        touch "$keyfile" "$keyfile.pub"'
    make_stub sudo 'echo "sudo $*" >> "$STUB_LOG"; exit 0'

    qs_run 'PATH="$STUBS:$PATH"
            CLONE_SOURCE="https://github.com/me/proj"
            SANDBOX_NAME=demo QUICKSAND_USER=qs-bats-nonexistent
            QS_REPOS_DIR="$BATS_TEST_TMPDIR/ws/repos"
            QS_SSH_DIR="$BATS_TEST_TMPDIR/ws/.ssh"
            INSTALL_DIR="$BATS_TEST_TMPDIR"
            QS_CLONES_MANIFEST="$BATS_TEST_TMPDIR/manifest"
            QS_PRIVATE_DIR="$BATS_TEST_TMPDIR/ws/_quicksand"
            CLONE_DEST_OVERRIDE="$BATS_TEST_TMPDIR/ws/memory"
            CLONE_KEY_NAME=memory
            do_clone'
    [ "$status" -eq 0 ]
    grep -q "git clone git@github.com:me/proj.git $BATS_TEST_TMPDIR/ws/memory" "$STUB_LOG"
    grep -q "qs:demo:memory" "$STUB_LOG"
    grep -q "ln -sfn $BATS_TEST_TMPDIR/ws/memory /Users/qs-bats-nonexistent/memory" "$STUB_LOG"
    [[ -f "$BATS_TEST_TMPDIR/ws/.ssh/id_ed25519_memory" ]]
}

###############################################################################
# qs memory (git/gh/ssh-keygen/sudo stubbed)
###############################################################################

@test "parse_args resolves memory and requires OWNER/REPO" {
    qs_run 'parse_args memory foo owner/mem
            echo "$COMMAND $SANDBOX_NAME $MEMORY_REPO"'
    [ "$status" -eq 0 ]
    [[ "$output" == "memory foo owner/mem" ]]

    qs_run 'parse_args memory foo'
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires OWNER/REPO"* ]]
}

@test "cmd_memory clones to the memory dir with its own key, manifest and identity" {
    make_stub git 'echo "git $*" >> "$STUB_LOG"
        [[ "$1" == "clone" ]] && mkdir -p "$3"
        exit 0'
    make_stub gh 'echo "gh $*" >> "$STUB_LOG"; exit 0'
    make_stub ssh-keygen 'while [[ $# -gt 0 ]]; do
            [[ "$1" == "-f" ]] && keyfile="$2"
            shift
        done
        touch "$keyfile" "$keyfile.pub"'
    make_stub sudo 'echo "sudo $*" >> "$STUB_LOG"; exit 0'

    export MEM_MANIFEST="$BATS_TEST_TMPDIR/memory-manifest"
    qs_run 'PATH="$STUBS:$PATH"
            MEMORY_REPO="me/agent-memory"
            SANDBOX_NAME=demo QUICKSAND_USER=qs-bats-nonexistent
            QS_MEMORY_DIR="$BATS_TEST_TMPDIR/ws/memory"
            QS_REPOS_DIR="$BATS_TEST_TMPDIR/ws/repos"
            QS_SSH_DIR="$BATS_TEST_TMPDIR/ws/.ssh"
            QS_PRIVATE_DIR="$BATS_TEST_TMPDIR/ws/_quicksand"
            INSTALL_DIR="$BATS_TEST_TMPDIR"
            QS_CLONES_MANIFEST="$BATS_TEST_TMPDIR/clones-manifest"
            QS_MEMORY_MANIFEST="$MEM_MANIFEST"
            COMMAND_ARGS=()
            cmd_memory'
    [ "$status" -eq 0 ]
    grep -q "git clone git@github.com:me/agent-memory.git $BATS_TEST_TMPDIR/ws/memory" "$STUB_LOG"
    grep -q "qs:demo:memory" "$STUB_LOG"
    grep -q "config user.name qs-demo" "$STUB_LOG"
    grep -q "$(printf 'agent-memory\tme/agent-memory\t')" "$MEM_MANIFEST"
    [[ ! -f "$BATS_TEST_TMPDIR/clones-manifest" ]]
    [[ -f "$BATS_TEST_TMPDIR/ws/.ssh/id_ed25519_memory" ]]
}

@test "cmd_memory refuses when the memory dir already exists" {
    mkdir -p "$BATS_TEST_TMPDIR/ws/memory"
    qs_run 'MEMORY_REPO="me/agent-memory"
            SANDBOX_NAME=demo
            QS_MEMORY_DIR="$BATS_TEST_TMPDIR/ws/memory"
            COMMAND_ARGS=()
            cmd_memory'
    [ "$status" -ne 0 ]
    [[ "$output" == *"already exists"* ]]
}

@test "cleanup_memory_artifacts deletes the deploy key and manifest" {
    make_stub gh 'echo "gh $*" >> "$STUB_LOG"
        if [[ "$3" == "list" ]]; then
            printf "77\tqs:demo:memory\n"
        fi
        exit 0'
    export MEM_MANIFEST="$BATS_TEST_TMPDIR/memory-manifest"
    printf 'agent-memory\tme/agent-memory\t\n' > "$MEM_MANIFEST"
    qs_run 'PATH="$STUBS:$PATH"
            SANDBOX_NAME=demo
            QS_MEMORY_MANIFEST="$MEM_MANIFEST"
            cleanup_memory_artifacts'
    [ "$status" -eq 0 ]
    grep -q "gh repo deploy-key delete 77 -R me/agent-memory" "$STUB_LOG"
    [[ ! -f "$MEM_MANIFEST" ]]
}


@test "do_clone escapes the deploy key path for shell re-parsing" {
    make_stub git 'echo "git $*" >> "$STUB_LOG"
        [[ "$1" == "clone" ]] && mkdir -p "$3"
        exit 0'
    make_stub gh 'exit 0'
    make_stub ssh-keygen 'while [[ $# -gt 0 ]]; do
            [[ "$1" == "-f" ]] && keyfile="$2"
            shift
        done
        touch "$keyfile" "$keyfile.pub"'
    make_stub sudo 'exit 0'

    qs_run 'PATH="$STUBS:$PATH"
            CLONE_SOURCE="https://github.com/me/proj"
            SANDBOX_NAME=demo QUICKSAND_USER=qs-bats-nonexistent
            QS_REPOS_DIR="$BATS_TEST_TMPDIR/ws dir/repos"
            QS_SSH_DIR="$BATS_TEST_TMPDIR/ws dir/.ssh"
            INSTALL_DIR="$BATS_TEST_TMPDIR"
            QS_CLONES_MANIFEST="$BATS_TEST_TMPDIR/manifest"
            QS_PRIVATE_DIR="$BATS_TEST_TMPDIR/ws dir/_quicksand"
            do_clone'
    [ "$status" -eq 0 ]
    local esc
    esc="$(printf '%q' "$BATS_TEST_TMPDIR/ws dir/.ssh/id_ed25519_proj")"
    grep -qF "ssh -i $esc" "$STUB_LOG"
}


###############################################################################
# gh auth provider (libexec/qs-auth-gh) and repo-ref parsing
###############################################################################

@test "parse_args resolves gh-auth and its optional repo arg" {
    qs_run 'parse_args gh-auth foo owner/repo
            echo "$COMMAND $SANDBOX_NAME $GH_AUTH_REPO"'
    [ "$status" -eq 0 ]
    [[ "$output" == "gh-auth foo owner/repo" ]]
}

@test "parse_args resolves the g alias for gh-auth" {
    qs_run 'parse_args g foo; echo "$COMMAND"'
    [[ "$output" == "gh-auth" ]]
}

@test "gh-auth repo arg is optional" {
    qs_run 'parse_args gh-auth foo; echo "$COMMAND [$GH_AUTH_REPO]"'
    [ "$status" -eq 0 ]
    [[ "$output" == "gh-auth []" ]]
}

@test "parse_github_repo handles OWNER/REPO, https and git URLs" {
    qs_run 'for r in octo/Hi https://github.com/octo/Hi.git \
                     https://github.com/octo/Hi git@github.com:octo/Hi.git; do
                parse_github_repo "$r" && echo "$PG_OWNER/$PG_REPO/$PG_NAME"
            done'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | sort -u)" == "octo/Hi/Hi" ]]
}

@test "parse_github_repo rejects a non-repo string" {
    qs_run 'parse_github_repo "not-a-repo"'
    [ "$status" -ne 0 ]
}

# Run a bash snippet with the gh provider sourced under the standard env
# contract (its main is guarded against sourcing, mirroring qs itself).
gh_run() {
    run bash -c "export QS_SANDBOX_NAME=demo \
            QS_PRIVATE_DIR=\"\$BATS_TEST_TMPDIR/priv\"
        source \"\$REPO_COPY/libexec/qs-auth-gh\"; $1"
}

# Execute the provider the way qs's run_auth_provider does: verb as argv,
# context via QS_* env, stubs first on PATH. The sandbox name is fixed to
# 'demo' (never inherited — the suite may itself run inside a sandbox that
# exports QS_SANDBOX_NAME); override the private dir per-test via GH_PRIV.
gh_exec() {
    run env PATH="$STUBS:$PATH" \
        QS_SANDBOX_NAME=demo \
        QS_PRIVATE_DIR="${GH_PRIV:-$BATS_TEST_TMPDIR/priv}" \
        "$REPO_COPY/libexec/qs-auth-gh" "$@"
}

@test "url_encode percent-encodes reserved characters" {
    gh_run 'url_encode "qs:demo:my repo"'
    [[ "$output" == "qs%3Ademo%3Amy%20repo" ]]
}

@test "qs-auth-gh rejects unknown verbs" {
    gh_exec frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage: qs-auth-gh"* ]]
}

@test "detect_single_github_clone picks the lone GitHub clone" {
    export MANIFEST="$BATS_TEST_TMPDIR/manifest"
    printf 'proj\tme/proj\t\n' > "$MANIFEST"
    qs_run 'QS_CLONES_MANIFEST="$MANIFEST"
            detect_single_github_clone && echo "$PG_OWNER/$PG_REPO/$PG_NAME"'
    [ "$status" -eq 0 ]
    [[ "$output" == "me/proj/proj" ]]
}

@test "detect_single_github_clone fails when there are several clones" {
    export MANIFEST="$BATS_TEST_TMPDIR/manifest"
    printf 'a\tme/a\t\nb\tme/b\t\n' > "$MANIFEST"
    qs_run 'QS_CLONES_MANIFEST="$MANIFEST"; detect_single_github_clone'
    [ "$status" -ne 0 ]
}

@test "detect_single_github_clone ignores non-GitHub (no owner) clones" {
    export MANIFEST="$BATS_TEST_TMPDIR/manifest"
    printf 'local\t\t/some/path\n' > "$MANIFEST"
    qs_run 'QS_CLONES_MANIFEST="$MANIFEST"; detect_single_github_clone'
    [ "$status" -ne 0 ]
}

@test "qs-auth-gh provision is a no-op on non-interactive stdin" {
    gh_exec provision owner repo
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/priv/gh-token-repo" ]
}

@test "qs-auth-gh provision requires OWNER and REPO" {
    gh_exec provision owner
    [ "$status" -ne 0 ]
    [[ "$output" == *"provision needs OWNER REPO"* ]]
}

@test "cmd_gh_auth requires a repo when none can be detected" {
    qs_run 'COMMAND_ARGS=(); GH_AUTH_REPO=""; SANDBOX_NAME=demo
            QS_CLONES_MANIFEST="$BATS_TEST_TMPDIR/none"
            cmd_gh_auth'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Specify which repo"* ]]
}

@test "cmd_gh_auth dispatches the detected repo to the gh provider" {
    export MANIFEST="$BATS_TEST_TMPDIR/manifest"
    printf 'proj\tme/proj\t\n' > "$MANIFEST"
    qs_run 'COMMAND_ARGS=(); GH_AUTH_REPO=""; SANDBOX_NAME=demo
            QS_CLONES_MANIFEST="$MANIFEST"
            QS_PRIVATE_DIR="$BATS_TEST_TMPDIR/priv" INSTALL_DIR="$BATS_TEST_TMPDIR"
            cmd_gh_auth'
    [ "$status" -eq 0 ]
}

@test "qs-auth-gh cleanup reminds about saved tokens that can't be API-revoked" {
    mkdir -p "$BATS_TEST_TMPDIR/priv"
    touch "$BATS_TEST_TMPDIR/priv/gh-token-repo"
    gh_exec cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"can't be revoked via API"* ]]
}


###############################################################################
# GCP auth provider (libexec/qs-auth-gcp; gcloud stubbed)
###############################################################################

# Run a bash snippet with the gcp provider sourced under the standard env
# contract (its main is guarded against sourcing, mirroring qs itself).
gcp_run() {
    run bash -c "export QS_SANDBOX_NAME=work \
            QS_PRIVATE_DIR=\"\$BATS_TEST_TMPDIR/priv\" \
            QS_INSTALL_DIR=\"\$BATS_TEST_TMPDIR\"
        source \"\$REPO_COPY/libexec/qs-auth-gcp\"; $1"
}

# Execute the provider the way qs's run_auth_provider does: verb as argv,
# context via QS_* env, stubs first on PATH. The sandbox name is fixed to
# 'work' (never inherited — the suite may itself run inside a sandbox that
# exports QS_SANDBOX_NAME); override the private dir per-test via GCP_PRIV.
gcp_exec() {
    run env PATH="$STUBS:$PATH" \
        QS_SANDBOX_NAME=work \
        QS_PRIVATE_DIR="${GCP_PRIV:-$BATS_TEST_TMPDIR/priv}" \
        QS_INSTALL_DIR="$BATS_TEST_TMPDIR" \
        "$REPO_COPY/libexec/qs-auth-gcp" "$@"
}

@test "parse_args resolves gcp-auth and its target project arg" {
    qs_run 'parse_args gcp-auth work metadata-dev-4d18
            echo "$COMMAND $SANDBOX_NAME ${GCP_TARGET_PROJECTS[*]}"'
    [ "$status" -eq 0 ]
    [[ "$output" == "gcp-auth work metadata-dev-4d18" ]]
}

@test "parse_args collects multiple gcp-auth target projects" {
    qs_run 'parse_args gcp-auth work metadata-dev-4d18 shared-packages-fad1
            echo "${#GCP_TARGET_PROJECTS[@]}: ${GCP_TARGET_PROJECTS[*]}"'
    [ "$status" -eq 0 ]
    [[ "$output" == "2: metadata-dev-4d18 shared-packages-fad1" ]]
}

@test "parse_args resolves the gp alias for gcp-auth" {
    qs_run 'parse_args gp work; echo "$COMMAND"'
    [[ "$output" == "gcp-auth" ]]
}

@test "parse_args resolves gcp-token and its gt alias" {
    qs_run 'parse_args gcp-token work; echo "$COMMAND $SANDBOX_NAME"'
    [ "$status" -eq 0 ]
    [[ "$output" == "gcp-token work" ]]
    qs_run 'parse_args gt work; echo "$COMMAND"'
    [[ "$output" == "gcp-token" ]]
}

@test "qs-auth-gcp rejects unknown verbs" {
    gcp_exec frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage: qs-auth-gcp"* ]]
}

@test "gcp_sa_id_from_name lowercases and maps underscores" {
    gcp_run 'gcp_sa_id_from_name "My_Work"; echo "$GCP_SA_ID"'
    [ "$status" -eq 0 ]
    [ "$output" == "qs-my-work" ]
}

@test "gcp_sa_id_from_name rejects names too short to be valid" {
    gcp_run 'gcp_sa_id_from_name "ab"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"valid GCP service-account id"* ]]
}

# A gcloud stub covering the whole provisioning flow: SA absent → created,
# role + token-creator bindings succeed, active account resolves, token mints.
gcloud_provision_stub() {
    make_stub gcloud 'echo "gcloud $*" >> "$STUB_LOG"
        case "$1 $2 $3" in
            "iam service-accounts describe") exit 1 ;;             # not yet present
        esac
        case "$1 $2" in
            "auth list") echo "ivan@example.com" ;;
            "auth print-access-token") echo "ya29.fake-token" ;;
        esac
        exit 0'
}

@test "gcp_sa_setup creates the SA, grants roles + token-creator, writes token/sa/project/manifest" {
    gcloud_provision_stub
    export PRIV="$BATS_TEST_TMPDIR/priv"
    export MANIFEST="$BATS_TEST_TMPDIR/gcp-manifest"
    gcp_run 'PATH="$STUBS:$PATH"
            QS_GCP_MANIFEST="$MANIFEST"
            QS_PRIVATE_DIR="$PRIV"
            gcp_sa_setup ivan-drinchev work metadata-dev-4d18'
    [ "$status" -eq 0 ]
    [ "$(cat "$PRIV/gcp-token")" == "ya29.fake-token" ]
    local sa="qs-work@ivan-drinchev.iam.gserviceaccount.com"
    [ "$(cat "$PRIV/gcp-sa")" == "$sa" ]
    [ "$(cat "$PRIV/gcp-project")" == "metadata-dev-4d18" ]
    grep -q "service-accounts create qs-work" "$STUB_LOG"
    grep -q "service-accounts add-iam-policy-binding $sa .*serviceAccountTokenCreator" "$STUB_LOG"
    grep -qF "$(printf '%s\t%s\t%s\t%s' ivan-drinchev "$sa" metadata-dev-4d18 roles/viewer)" "$MANIFEST"
    grep -qF "roles/artifactregistry.reader" "$MANIFEST"
}

@test "gcp_sa_setup grants roles on every target project and pins the first" {
    gcloud_provision_stub
    export PRIV="$BATS_TEST_TMPDIR/priv"
    export MANIFEST="$BATS_TEST_TMPDIR/gcp-manifest"
    gcp_run 'PATH="$STUBS:$PATH"
            QS_GCP_MANIFEST="$MANIFEST"
            QS_PRIVATE_DIR="$PRIV"
            gcp_sa_setup ivan-drinchev work metadata-dev-4d18 shared-packages-fad1'
    [ "$status" -eq 0 ]
    local sa="qs-work@ivan-drinchev.iam.gserviceaccount.com"
    # First target becomes the sandbox default project.
    [ "$(cat "$PRIV/gcp-project")" == "metadata-dev-4d18" ]
    # The reader role is granted (and recorded) on BOTH projects.
    grep -q "projects add-iam-policy-binding metadata-dev-4d18 .*--role=roles/artifactregistry.reader" "$STUB_LOG"
    grep -q "projects add-iam-policy-binding shared-packages-fad1 .*--role=roles/artifactregistry.reader" "$STUB_LOG"
    grep -qF "$(printf '%s\t%s\t%s\t%s' ivan-drinchev "$sa" shared-packages-fad1 roles/artifactregistry.reader)" "$MANIFEST"
}

@test "gcp_sa_setup honours a QS_GCP_ROLES override" {
    gcloud_provision_stub
    export PRIV="$BATS_TEST_TMPDIR/priv"
    export MANIFEST="$BATS_TEST_TMPDIR/gcp-manifest"
    gcp_run 'PATH="$STUBS:$PATH"
            QS_GCP_MANIFEST="$MANIFEST" QS_PRIVATE_DIR="$PRIV"
            QS_GCP_ROLES="roles/storage.admin"
            gcp_sa_setup owner work target'
    [ "$status" -eq 0 ]
    grep -qF "roles/storage.admin" "$MANIFEST"
    ! grep -qF "roles/viewer" "$MANIFEST"
}

@test "gcp_sa_setup reuses an existing service account" {
    make_stub gcloud 'echo "gcloud $*" >> "$STUB_LOG"
        case "$1 $2 $3" in
            "iam service-accounts describe") exit 0 ;;            # already present
        esac
        case "$1 $2" in
            "auth list") echo "ivan@example.com" ;;
            "auth print-access-token") echo "ya29.fake-token" ;;
        esac
        exit 0'
    export PRIV="$BATS_TEST_TMPDIR/priv"
    gcp_run 'PATH="$STUBS:$PATH"
            QS_GCP_MANIFEST="$BATS_TEST_TMPDIR/gcp-manifest" QS_PRIVATE_DIR="$PRIV"
            gcp_sa_setup owner work target'
    [ "$status" -eq 0 ]
    [[ "$output" == *"already exists"* ]]
    ! grep -q "service-accounts create" "$STUB_LOG"
}

@test "gcp_mint_token writes the impersonated token to the workspace" {
    make_stub gcloud 'echo "gcloud $*" >> "$STUB_LOG"
        [[ "$1 $2" == "auth print-access-token" ]] && echo "ya29.minted"
        exit 0'
    export PRIV="$BATS_TEST_TMPDIR/priv"
    gcp_run 'PATH="$STUBS:$PATH"; QS_PRIVATE_DIR="$PRIV"
            gcp_mint_token qs-work@owner.iam.gserviceaccount.com'
    [ "$status" -eq 0 ]
    [ "$(cat "$PRIV/gcp-token")" == "ya29.minted" ]
    grep -q "print-access-token --impersonate-service-account=qs-work@owner.iam.gserviceaccount.com" "$STUB_LOG"
}

@test "qs-auth-gcp mint requires a provisioned service account" {
    make_stub gcloud 'exit 0'
    GCP_PRIV="$BATS_TEST_TMPDIR/empty" gcp_exec mint
    [ "$status" -ne 0 ]
    [[ "$output" == *"No GCP service account recorded"* ]]
}

@test "cmd_gcp_token dispatches through the provider with the env contract" {
    make_stub gcloud '[[ "$1 $2" == "auth print-access-token" ]] && echo "ya29.dispatched"; exit 0'
    export PRIV="$BATS_TEST_TMPDIR/priv"; mkdir -p "$PRIV"
    printf 'qs-work@owner.iam.gserviceaccount.com\n' > "$PRIV/gcp-sa"
    qs_run 'PATH="$STUBS:$PATH"; COMMAND_ARGS=(); SANDBOX_NAME=work
            QS_PRIVATE_DIR="$PRIV" INSTALL_DIR="$BATS_TEST_TMPDIR"
            cmd_gcp_token'
    [ "$status" -eq 0 ]
    [ "$(cat "$PRIV/gcp-token")" == "ya29.dispatched" ]
}

@test "qs-auth-gcp refresh is a no-op for a sandbox without GCP" {
    make_stub gcloud 'echo "gcloud $*" >> "$STUB_LOG"; exit 0'
    GCP_PRIV="$BATS_TEST_TMPDIR/empty" gcp_exec refresh
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_LOG" ] || ! grep -q "print-access-token" "$STUB_LOG"
}

@test "qs-auth-gcp refresh mints when the token is missing" {
    make_stub gcloud 'echo "gcloud $*" >> "$STUB_LOG"
        [[ "$1 $2" == "auth print-access-token" ]] && echo "ya29.fresh"
        exit 0'
    export PRIV="$BATS_TEST_TMPDIR/priv"; mkdir -p "$PRIV"
    printf 'qs-work@owner.iam.gserviceaccount.com\n' > "$PRIV/gcp-sa"
    gcp_exec refresh
    [ "$status" -eq 0 ]
    [ "$(cat "$PRIV/gcp-token")" == "ya29.fresh" ]
}

@test "qs-auth-gcp refresh skips when the token is still fresh" {
    make_stub gcloud 'echo "gcloud $*" >> "$STUB_LOG"
        [[ "$1 $2" == "auth print-access-token" ]] && echo "ya29.new"
        exit 0'
    export PRIV="$BATS_TEST_TMPDIR/priv"; mkdir -p "$PRIV"
    printf 'qs-work@owner.iam.gserviceaccount.com\n' > "$PRIV/gcp-sa"
    printf 'ya29.existing\n' > "$PRIV/gcp-token"   # just written → young
    gcp_exec refresh
    [ "$status" -eq 0 ]
    [ "$(cat "$PRIV/gcp-token")" == "ya29.existing" ]
    [ ! -f "$STUB_LOG" ] || ! grep -q "print-access-token" "$STUB_LOG"
}

@test "qs-auth-gcp refresh re-mints when the token is stale" {
    make_stub gcloud 'echo "gcloud $*" >> "$STUB_LOG"
        [[ "$1 $2" == "auth print-access-token" ]] && echo "ya29.new"
        exit 0'
    export PRIV="$BATS_TEST_TMPDIR/priv"; mkdir -p "$PRIV"
    printf 'qs-work@owner.iam.gserviceaccount.com\n' > "$PRIV/gcp-sa"
    printf 'ya29.old\n' > "$PRIV/gcp-token"
    touch -t 202001010000 "$PRIV/gcp-token"   # ancient → stale
    gcp_exec refresh
    [ "$status" -eq 0 ]
    [ "$(cat "$PRIV/gcp-token")" == "ya29.new" ]
}

@test "qs-auth-gcp cleanup removes each binding and deletes the SA once" {
    make_stub gcloud 'echo "gcloud $*" >> "$STUB_LOG"; exit 0'
    local sa="qs-work@owner.iam.gserviceaccount.com"
    printf 'owner\t%s\ttarget\troles/viewer\n' "$sa" > "$BATS_TEST_TMPDIR/gcp-work"
    printf 'owner\t%s\ttarget\troles/artifactregistry.reader\n' "$sa" >> "$BATS_TEST_TMPDIR/gcp-work"
    gcp_exec cleanup
    [ "$status" -eq 0 ]
    grep -q "remove-iam-policy-binding target .*--role=roles/viewer" "$STUB_LOG"
    grep -q "remove-iam-policy-binding target .*--role=roles/artifactregistry.reader" "$STUB_LOG"
    [ "$(grep -c "service-accounts delete $sa" "$STUB_LOG")" -eq 1 ]
    [ ! -f "$BATS_TEST_TMPDIR/gcp-work" ]
}

@test "uninstall's provider loop runs the gcp cleanup" {
    make_stub gcloud 'echo "gcloud $*" >> "$STUB_LOG"; exit 0'
    printf 'owner\tqs-work@owner.iam.gserviceaccount.com\ttarget\troles/viewer\n' \
        > "$BATS_TEST_TMPDIR/gcp-work"
    qs_run 'PATH="$STUBS:$PATH"; SANDBOX_NAME=work
            QS_PRIVATE_DIR="$BATS_TEST_TMPDIR/priv" INSTALL_DIR="$BATS_TEST_TMPDIR"
            run_all_auth_providers cleanup'
    [ "$status" -eq 0 ]
    grep -q "remove-iam-policy-binding target" "$STUB_LOG"
    [ ! -f "$BATS_TEST_TMPDIR/gcp-work" ]
}

@test "qs-auth-gcp provision needs a terminal to confirm the owner project" {
    make_stub gcloud 'exit 0'
    gcp_exec provision someproj
    [ "$status" -ne 0 ]
    [[ "$output" == *"interactive terminal"* ]]
}

@test "cmd_gcp_auth requires a target project" {
    qs_run 'COMMAND_ARGS=(); GCP_TARGET_PROJECTS=()
            SANDBOX_NAME=work; cmd_gcp_auth'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Specify at least one project to grant access on"* ]]
}


###############################################################################
# 1Password auth provider (libexec/qs-auth-op; op stubbed)
###############################################################################

# Execute the provider the way qs's run_auth_provider does: verb as argv,
# context via QS_* env, stubs first on PATH. The sandbox name is fixed to
# 'work' (never inherited — the suite may itself run inside a sandbox that
# exports QS_SANDBOX_NAME); override the private dir per-test via OP_PRIV.
op_exec() {
    run env PATH="$STUBS:$PATH" \
        QS_SANDBOX_NAME=work \
        QS_PRIVATE_DIR="${OP_PRIV:-$BATS_TEST_TMPDIR/priv}" \
        QS_INSTALL_DIR="$BATS_TEST_TMPDIR" \
        "$REPO_COPY/libexec/qs-auth-op" "$@"
}

# An op stub covering the whole provisioning flow: signed in, vault absent
# (so the create path runs), service account minted, item stored.
op_provision_stub() {
    make_stub op 'echo "op $*" >> "$STUB_LOG"
        case "$1 $2" in
            "vault get") exit 1 ;;                      # not yet present
            "service-account create") echo "ops_fake-token" ;;
        esac
        exit 0'
}

@test "qs-auth-op rejects unknown verbs" {
    op_exec frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *"usage: qs-auth-op"* ]]
}

@test "qs-auth-op provision creates vault + scoped SA and records the manifest" {
    op_provision_stub
    op_exec provision
    [ "$status" -eq 0 ]
    grep -q "vault create qs-work" "$STUB_LOG"
    grep -q "service-account create qs-work --expires-in 90d --vault qs-work:read_items" "$STUB_LOG"
    grep -q "item create --category Password --title quicksand-service-account --vault qs-work" "$STUB_LOG"
    [ "$(cat "$BATS_TEST_TMPDIR/op-work")" == "$(printf 'qs-work\tquicksand-service-account\tqs-work')" ]
    [[ "$output" == *"read-only; pass --write"* ]]
}

@test "qs-auth-op provision --write grants write_items and drops the hint" {
    op_provision_stub
    op_exec provision --write
    [ "$status" -eq 0 ]
    grep -q -- "--vault qs-work:read_items,write_items" "$STUB_LOG"
    [[ "$output" != *"read-only; pass --write"* ]]
}

@test "qs-auth-op provision reuses an existing vault" {
    make_stub op 'echo "op $*" >> "$STUB_LOG"
        case "$1 $2" in
            "service-account create") echo "ops_fake-token" ;;
        esac
        exit 0'                                          # vault get succeeds
    op_exec provision
    [ "$status" -eq 0 ]
    [[ "$output" == *"already exists"* ]]
    ! grep -q "vault create" "$STUB_LOG"
}

@test "qs-auth-op refresh stages the token 0600 from the vault" {
    make_stub op 'echo "op $*" >> "$STUB_LOG"
        [[ "$1" == "read" ]] && echo "ops_staged-token"
        exit 0'
    printf 'qs-work\tquicksand-service-account\tqs-work\n' > "$BATS_TEST_TMPDIR/op-work"
    op_exec refresh
    [ "$status" -eq 0 ]
    grep -q "read op://qs-work/quicksand-service-account/password" "$STUB_LOG"
    [ "$(cat "$BATS_TEST_TMPDIR/priv/op-token")" == "ops_staged-token" ]
    [ "$(/usr/bin/stat -f %Lp "$BATS_TEST_TMPDIR/priv/op-token")" == "600" ]
}

@test "qs-auth-op refresh is a no-op for a sandbox without op" {
    make_stub op 'echo "op $*" >> "$STUB_LOG"; exit 0'
    op_exec refresh
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_LOG" ]
    [ ! -e "$BATS_TEST_TMPDIR/priv/op-token" ]
}

@test "qs-auth-op refresh warns but succeeds when the vault is unreadable" {
    make_stub op 'exit 1'                               # locked / no access
    printf 'qs-work\tquicksand-service-account\tqs-work\n' > "$BATS_TEST_TMPDIR/op-work"
    op_exec refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not read the 1Password token"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/priv/op-token" ]
}

@test "qs-auth-op refresh retries with the app integration stated in the environment" {
    # op as it behaves when macOS hides 1Password's settings file from it.
    make_stub op 'echo "op $* biometric=${OP_BIOMETRIC_UNLOCK_ENABLED:-unset}" >> "$STUB_LOG"
        if [[ "${OP_BIOMETRIC_UNLOCK_ENABLED:-}" != "true" ]]; then
            echo "No accounts configured for use with 1Password CLI." >&2; exit 1
        fi
        echo "ops_via-env"'
    printf 'qs-work\tquicksand-service-account\tqs-work\n' > "$BATS_TEST_TMPDIR/op-work"
    op_exec refresh
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING"* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/priv/op-token")" == "ops_via-env" ]
    [ "$(grep -c "^op read" "$STUB_LOG")" -eq 2 ]
    grep -q "biometric=unset" "$STUB_LOG"
    grep -q "biometric=true" "$STUB_LOG"
}

@test "qs-auth-op refresh passes on op's own error when the read fails" {
    make_stub op 'echo "[ERROR] 2026/11/18 connecting to desktop app: not running" >&2; exit 1'
    printf 'qs-work\tquicksand-service-account\tqs-work\n' > "$BATS_TEST_TMPDIR/op-work"
    op_exec refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not read the 1Password token for 'work' (op said: [ERROR] 2026/11/18 connecting to desktop app: not running) — unlock"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/priv/op-token" ]
}

@test "qs-auth-op cleanup deletes the token item and reminds about the SA" {
    make_stub op 'echo "op $*" >> "$STUB_LOG"; exit 0'
    printf 'qs-work\tquicksand-service-account\tqs-work\n' > "$BATS_TEST_TMPDIR/op-work"
    op_exec cleanup
    [ "$status" -eq 0 ]
    grep -q "item delete quicksand-service-account --vault qs-work" "$STUB_LOG"
    [[ "$output" == *"Revoke the service account 'qs-work'"* ]]
    [[ "$output" == *"vault 'qs-work' and its secrets intact"* ]]
    [ ! -f "$BATS_TEST_TMPDIR/op-work" ]
}

@test "cmd_op_auth dispatches --write through the provider" {
    op_provision_stub
    qs_run 'PATH="$STUBS:$PATH"; COMMAND_ARGS=(); OP_WRITE=true
            SANDBOX_NAME=work
            QS_PRIVATE_DIR="$BATS_TEST_TMPDIR/priv" INSTALL_DIR="$BATS_TEST_TMPDIR"
            cmd_op_auth'
    [ "$status" -eq 0 ]
    grep -q -- "--vault qs-work:read_items,write_items" "$STUB_LOG"
    [ -f "$BATS_TEST_TMPDIR/op-work" ]
}

# Regression: in real runs derive_constants declares the qs globals
# readonly, and bash rejects `VAR=x cmd` env-prefix assignments for
# readonly names — the dispatch must build the child env via `env`.
@test "run_auth_provider works when qs constants are readonly" {
    make_stub op '[[ "$1" == "read" ]] && echo "tok-ro"; exit 0'
    printf 'qs-work\tquicksand-service-account\tqs-work\n' > "$BATS_TEST_TMPDIR/op-work"
    qs_run 'PATH="$STUBS:$PATH"; SANDBOX_NAME=work
            readonly QS_PRIVATE_DIR="$BATS_TEST_TMPDIR/priv" INSTALL_DIR="$BATS_TEST_TMPDIR"
            run_all_auth_providers refresh'
    [ "$status" -eq 0 ]
    [[ "$output" != *"readonly variable"* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/priv/op-token")" == "tok-ro" ]
}


###############################################################################
# docker broker — config/qs-docker-broker run directly against a stub docker
###############################################################################

# Run the broker as `launchd` would (request on stdin, reply on stdout) with
# the workspace at $WS and a stub docker that prints its argv. Tests that
# need custom docker behavior overwrite the stub before calling this.
broker() {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    [[ -x "$STUBS/docker" ]] \
        || make_stub docker 'printf "DOCKER:"; printf " %s" "$@"; printf "\n"'
    # Resolved path: $BATS_TEST_TMPDIR sits under the /var → /private/var
    # symlink, and the broker canonicalizes its workspace argument.
    mkdir -p "$BATS_TEST_TMPDIR/ws"
    WS="$(cd "$BATS_TEST_TMPDIR/ws" && pwd -P)"
    run bash -c "HOME=\"$BATS_TEST_TMPDIR\" \
        bash \"$REPO_COPY/config/qs-docker-broker\" work \"$WS\" \
        \"$STUBS/docker\" \"\$(command -v jq)\" <<< '$1'"
}

@test "docker broker run composes the hardened template" {
    broker '{"v":1,"verb":"run","image":"node:20","cmd":["node","-e","x"],"env":{"FOO":"bar baz"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"DOCKER: run --rm -i --label quicksand.sandbox=work --cap-drop ALL"* ]]
    [[ "$output" == *"-v $WS:$WS -w $WS"* ]]         # default workdir = workspace
    # _quicksand masked by an empty anonymous volume (no tokens, no socket)
    [[ "$output" == *"-w $WS -v $WS/_quicksand"* ]]
    [[ "$output" == *"-e FOO=bar baz node:20 node -e x"* ]]
    [[ "$output" == *"@@qs-docker-exit:0@@"* ]]
}

@test "docker broker rejects a workdir outside the workspace" {
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    broker "{\"v\":1,\"verb\":\"run\",\"image\":\"node:20\",\"workdir\":\"$BATS_TEST_TMPDIR/elsewhere\"}"
    [[ "$output" == *"workdir must be under"* ]]
    [[ "$output" != *"DOCKER:"* ]]
    [[ "$output" == *"@@qs-docker-exit:125@@"* ]]
}

@test "docker broker resolves ../ traversal before the workspace check" {
    mkdir -p "$BATS_TEST_TMPDIR/evil"
    broker "{\"v\":1,\"verb\":\"run\",\"image\":\"node:20\",\"workdir\":\"$BATS_TEST_TMPDIR/ws/../evil\"}"
    [[ "$output" == *"workdir must be under"* ]]
    [[ "$output" != *"DOCKER:"* ]]
}

@test "docker broker rejects flag injection via the image field" {
    broker '{"v":1,"verb":"run","image":"--privileged"}'
    [[ "$output" == *"bad image ref"* ]]
    [[ "$output" != *"DOCKER:"* ]]
}

@test "docker broker rejects malformed env names" {
    broker '{"v":1,"verb":"run","image":"node:20","env":{"BAD NAME":"x"}}'
    [[ "$output" == *"bad env name"* ]]
    [[ "$output" != *"DOCKER:"* ]]
}

@test "docker broker forces build tags into the sandbox namespace" {
    broker '{"v":1,"verb":"build","tag":"innocent/app","context":"/tmp"}'
    [[ "$output" == *"tag must live under qs-work/"* ]]
    [[ "$output" != *"DOCKER:"* ]]
}

@test "docker broker builds with an in-workspace context" {
    mkdir -p "$BATS_TEST_TMPDIR/ws/proj"
    broker "{\"v\":1,\"verb\":\"build\",\"tag\":\"qs-work/app\",\"context\":\"$BATS_TEST_TMPDIR/ws/proj\"}"
    [[ "$output" == *"DOCKER: build --label quicksand.sandbox=work -t qs-work/app $WS/proj"* ]]
    [[ "$output" == *"@@qs-docker-exit:0@@"* ]]
}

@test "docker broker rejects a build context outside the workspace" {
    broker '{"v":1,"verb":"build","tag":"qs-work/app","context":"/etc"}'
    [[ "$output" == *"context must be under"* ]]
    [[ "$output" != *"DOCKER:"* ]]
}

@test "docker broker rejects the workspace root as build context" {
    broker "{\"v\":1,\"verb\":\"build\",\"tag\":\"qs-work/app\",\"context\":\"$BATS_TEST_TMPDIR/ws\"}"
    [[ "$output" == *"not its root"* ]]
    [[ "$output" != *"DOCKER:"* ]]
}

@test "docker broker rejects a build context under _quicksand" {
    mkdir -p "$BATS_TEST_TMPDIR/ws/_quicksand"
    broker "{\"v\":1,\"verb\":\"build\",\"tag\":\"qs-work/app\",\"context\":\"$BATS_TEST_TMPDIR/ws/_quicksand\"}"
    [[ "$output" == *"must not be under _quicksand"* ]]
    [[ "$output" != *"DOCKER:"* ]]
}

@test "docker broker refuses verbs outside the allowlist" {
    broker '{"v":1,"verb":"exec","id":"whatever"}'
    [[ "$output" == *"unknown verb 'exec'"* ]]
    [[ "$output" != *"DOCKER:"* ]]
}

@test "docker broker rejects command injection in container ids" {
    broker '{"v":1,"verb":"logs","id":"$(rm -rf /)"}'
    [[ "$output" == *"bad container id"* ]]
    [[ "$output" != *"DOCKER:"* ]]
}

@test "docker broker refuses containers owned by another sandbox" {
    make_stub docker '[[ "$1" == "inspect" ]] && { echo "other"; exit 0; }
        printf "DOCKER:"; printf " %s" "$@"; printf "\n"'
    broker '{"v":1,"verb":"stop","id":"abc123"}'
    [[ "$output" == *"no such container"* ]]
    [[ "$output" != *"DOCKER: stop"* ]]
}

@test "docker broker rejects a non-JSON request" {
    broker 'not json at all'
    [[ "$output" == *"unparseable request"* ]]
    [[ "$output" != *"DOCKER:"* ]]
}

@test "docker broker puts the docker CLI's directory on PATH (credential helpers)" {
    # docker resolves docker-credential-* helpers via $PATH; under launchd's
    # bare PATH a pull would fail even for public images.
    make_stub docker 'printf "PATH:%s\n" "$PATH"'
    broker '{"v":1,"verb":"pull","image":"postgres:17-alpine"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"PATH:$STUBS:"* ]]
    [[ "$output" == *":/usr/local/bin:"* ]]
}


###############################################################################
# qs docker — CLI plumbing and host-side helpers
###############################################################################

@test "qs docker requires a sandbox name" {
    run "$QS" docker
    [ "$status" -eq 1 ]
    [[ "$output" == *"sandbox name required"* ]]
}

@test "qs docker rejects actions other than off" {
    run "$QS" docker work offf
    [ "$status" -eq 1 ]
    [[ "$output" == *"accepts 'off' or nothing"* ]]
}

@test "qs --help documents qs docker" {
    run "$QS" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"qs docker    NAME [off]"* ]]
}

@test "cmd_docker aborts when docker is missing on the host" {
    qs_run 'PATH="/usr/bin:/bin"; COMMAND_ARGS=(); DOCKER_ACTION=on
            SANDBOX_NAME=work; cmd_docker'
    [ "$status" -ne 0 ]
    [[ "$output" == *"docker CLI not found on host"* ]]
}

@test "docker_broker_install stages, renders, and loads the agent" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    make_stub launchctl 'echo "launchctl $*" >> "$STUB_LOG"'
    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    qs_run 'PATH="$STUBS:$PATH"; SANDBOX_NAME=work
            SHARED_WORKSPACE="$WORK/ws"; QS_PRIVATE_DIR="$WORK/ws/_quicksand"
            INSTALL_DIR="$WORK/install"
            QS_DOCKER_LABEL=com.quicksand.docker-broker.work
            QS_DOCKER_PLIST="$WORK/agent.plist"
            QS_DOCKER_BROKER_STAGED="$WORK/install/docker-broker-work.sh"
            HOME="$WORK"
            docker_broker_install /host/bin/docker /host/bin/jq'
    [ "$status" -eq 0 ]
    [ -x "$WORK/install/docker-broker-work.sh" ]
    [ -x "$WORK/ws/_quicksand/bin/qs-docker" ]
    grep -q "<string>/host/bin/docker</string>" "$WORK/agent.plist"
    grep -q "<string>$WORK/install/docker-broker-work.sh</string>" "$WORK/agent.plist"
    grep -q "$WORK/ws/_quicksand/docker-broker.sock" "$WORK/agent.plist"
    grep -q "launchctl bootstrap" "$STUB_LOG"
}

@test "cleanup_docker reaps labeled containers and images" {
    make_stub launchctl 'echo "launchctl $*" >> "$STUB_LOG"'
    make_stub docker 'echo "docker $*" >> "$STUB_LOG"
        case "$1" in
            ps)     echo "c1"; echo "c2" ;;
            images) echo "i1" ;;
        esac'
    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK/install" "$WORK/ws/_quicksand/bin"
    touch "$WORK/agent.plist" "$WORK/install/docker-broker-work.sh" \
          "$WORK/ws/_quicksand/bin/qs-docker"
    qs_run 'PATH="$STUBS:/usr/bin:/bin"; SANDBOX_NAME=work
            QS_PRIVATE_DIR="$WORK/ws/_quicksand"
            INSTALL_DIR="$WORK/install"
            QS_DOCKER_LABEL=com.quicksand.docker-broker.work
            QS_DOCKER_PLIST="$WORK/agent.plist"
            QS_DOCKER_BROKER_STAGED="$WORK/install/docker-broker-work.sh"
            cleanup_docker'
    [ "$status" -eq 0 ]
    [ ! -f "$WORK/agent.plist" ]
    [ ! -f "$WORK/install/docker-broker-work.sh" ]
    [ ! -f "$WORK/ws/_quicksand/bin/qs-docker" ]
    grep -q "docker ps -aq --filter label=quicksand.sandbox=work" "$STUB_LOG"
    grep -q "docker rm -f c1 c2" "$STUB_LOG"
    grep -q "docker rmi -f i1" "$STUB_LOG"
}


###############################################################################
# profile.d/00-lib.sh (shared hook helpers, sourced not executed)
###############################################################################

# Run a bash snippet with the hook lib sourced.
lib_run() {
    run bash -c ". \"\$REPO_COPY/profile.d/00-lib.sh\"; $1"
}

@test "00-lib.sh is not executable so the session hook loop skips it" {
    [ -f "$REPO_COPY/profile.d/00-lib.sh" ]
    [ ! -x "$REPO_COPY/profile.d/00-lib.sh" ]
}

@test "qs_arch maps arm64 and x86_64 to the caller's names" {
    make_stub uname 'echo arm64'
    lib_run 'PATH="$STUBS:$PATH"; qs_arch graviton intel'
    [ "$status" -eq 0 ]
    [ "$output" == "graviton" ]
    make_stub uname 'echo x86_64'
    lib_run 'PATH="$STUBS:$PATH"; qs_arch graviton intel'
    [ "$output" == "intel" ]
}

@test "qs_arch fails on an unknown machine" {
    make_stub uname 'echo mips'
    lib_run 'PATH="$STUBS:$PATH"; qs_arch a b'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unsupported arch"* ]]
}

@test "find_pnpm prefers PATH, falls back to install dirs, else fails" {
    lib_run 'PATH=/usr/bin:/bin HOME="$BATS_TEST_TMPDIR"; find_pnpm'
    [ "$status" -ne 0 ]
    mkdir -p "$BATS_TEST_TMPDIR/Library/pnpm/bin"
    printf '#!/bin/bash\n' > "$BATS_TEST_TMPDIR/Library/pnpm/bin/pnpm"
    chmod +x "$BATS_TEST_TMPDIR/Library/pnpm/bin/pnpm"
    lib_run 'PATH=/usr/bin:/bin HOME="$BATS_TEST_TMPDIR"; find_pnpm'
    [ "$status" -eq 0 ]
    [ "$output" == "$BATS_TEST_TMPDIR/Library/pnpm/bin/pnpm" ]
}

@test "ensure_collection tolerates already-exists and propagates real errors" {
    make_stub qmd 'case "$*" in
        *dup*)  echo "collection already exists"; exit 1 ;;
        *bad*)  echo "boom"; exit 1 ;;
        *)      exit 0 ;;
    esac'
    lib_run 'QMD="$STUBS/qmd"; ensure_collection /x --name fresh'
    [ "$status" -eq 0 ]
    lib_run 'QMD="$STUBS/qmd"; ensure_collection /x --name dup'
    [ "$status" -eq 0 ]
    lib_run 'QMD="$STUBS/qmd"; ensure_collection /x --name bad'
    [ "$status" -ne 0 ]
    [[ "$output" == *"boom"* ]]
}


###############################################################################
# host_default_browser / profile.d/70-default-browser.sh
###############################################################################

# Write a LaunchServices-prefs-shaped plist fixture; prints the path qs and
# the hook expect (defaults(1) appends .plist to the file it creates).
make_ls_prefs() {
    local plist="$BATS_TEST_TMPDIR/ls-prefs"
    defaults write "$plist" LSHandlers -array "$@"
    echo "$plist"
}

@test "host_default_browser extracts the https handler bundle id" {
    plist="$(make_ls_prefs \
        '{ LSHandlerContentType = "public.html"; LSHandlerRoleAll = "org.mozilla.firefox"; }' \
        '{ LSHandlerPreferredVersions = { LSHandlerRoleAll = "-"; }; LSHandlerRoleAll = "company.thebrowser.dia"; LSHandlerURLScheme = https; }' \
        '{ LSHandlerRoleAll = "com.apple.dt.xcode"; LSHandlerURLScheme = xcode; }')"
    qs_run "host_default_browser '$plist'"
    [ "$status" -eq 0 ]
    [ "$output" == "company.thebrowser.dia" ]
}

@test "host_default_browser fails when no https handler is recorded" {
    plist="$(make_ls_prefs \
        '{ LSHandlerContentType = "public.html"; LSHandlerRoleAll = "org.mozilla.firefox"; }')"
    qs_run "host_default_browser '$plist'"
    [ "$status" -ne 0 ]
    [[ "$output" != *"org.mozilla.firefox"* ]]
}

@test "host_default_browser fails when the prefs plist is missing" {
    qs_run "host_default_browser '$BATS_TEST_TMPDIR/absent'"
    [ "$status" -ne 0 ]
}

# The hook tests point QS_LS_PREFS at a literal file: defaults(1) treats a
# path under $HOME/Library/Preferences as a cfprefsd domain, so faking HOME
# would make the hook write into the *invoking* user's real preferences.

@test "70-default-browser no-ops when QS_HOST_BROWSER is unset" {
    run env -u QS_HOST_BROWSER QS_LS_PREFS="$BATS_TEST_TMPDIR/prefs/ls" \
        "$REPO_COPY/profile.d/70-default-browser.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/prefs" ]
}

@test "70-default-browser rejects a bundle id that could break the plist" {
    run env QS_HOST_BROWSER='bad"; LSHandlerRoleAll = "oops' \
        QS_LS_PREFS="$BATS_TEST_TMPDIR/prefs/ls" \
        "$REPO_COPY/profile.d/70-default-browser.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/prefs" ]
}

@test "70-default-browser writes both schemes idempotently; parser reads it back" {
    prefs="$BATS_TEST_TMPDIR/prefs/ls"
    run env QS_HOST_BROWSER=company.thebrowser.dia QS_LS_PREFS="$prefs" \
        "$REPO_COPY/profile.d/70-default-browser.sh"
    [ "$status" -eq 0 ]
    run defaults read "$prefs" LSHandlers
    [[ "$output" == *"LSHandlerURLScheme = http;"* ]]
    [[ "$output" == *"LSHandlerURLScheme = https;"* ]]
    # A second run must take the already-configured early exit — proven by
    # making a rewrite physically impossible (read-only prefs dir).
    chmod -w "$BATS_TEST_TMPDIR/prefs"
    run env QS_HOST_BROWSER=company.thebrowser.dia QS_LS_PREFS="$prefs" \
        "$REPO_COPY/profile.d/70-default-browser.sh"
    chmod +w "$BATS_TEST_TMPDIR/prefs"
    [ "$status" -eq 0 ]
    # Round-trip: the launcher-side detector parses what the hook wrote.
    qs_run "host_default_browser '$prefs'"
    [ "$status" -eq 0 ]
    [ "$output" == "company.thebrowser.dia" ]
}


###############################################################################
# configure_shared_folder_permissions (sudo stubbed to run the command as-is)
###############################################################################

# The ACL pass must skip Unix sockets: chmod +a fails on them ("Operation
# not supported on socket"), and launchd leaves broker sockets in
# _quicksand/. Run against a real fixture with a real socket; ACLs on the
# regular file prove the pass still did its job.
@test "workspace ACL pass skips sockets and still labels files" {
    make_stub sudo 'exec "$@"'
    # Short path: Unix socket paths are capped at 104 bytes, and
    # $BATS_TEST_TMPDIR alone is longer than that.
    export ACL_WS
    ACL_WS="$(mktemp -d /tmp/qs-acl.XXXXXX)"
    ws="$ACL_WS"
    mkdir -p "$ws/_quicksand"
    echo x > "$ws/_quicksand/file"
    nc -lU "$ws/_quicksand/say.sock" &
    listener=$!
    for _ in $(seq 1 50); do [ -S "$ws/_quicksand/say.sock" ] && break; sleep 0.1; done
    kill -9 "$listener" 2>/dev/null; wait "$listener" 2>/dev/null || true
    [ -S "$ws/_quicksand/say.sock" ]
    qs_run 'PATH="$STUBS:$PATH"; SHARED_WORKSPACE="$ACL_WS"
            HOST_USER="$(id -un)"; QUICKSAND_GROUP=everyone
            QS_DIR_RIGHTS="group:everyone allow read,search,list,directory_inherit"
            QS_FILE_INHERIT_RIGHTS="group:everyone allow read,file_inherit"
            QS_FILE_RIGHTS="group:everyone allow read"
            configure_shared_folder_permissions true'
    [ "$status" -eq 0 ]
    [[ "$output" != *"not supported on socket"* ]]
    ls -le "$ws/_quicksand/file" | grep -q "group:everyone allow read"
    rm -rf "$ws"
}


###############################################################################
# Speech: config/qs-say-broker, config/qs-say, profile.d/31-claude-say.sh,
# say_broker_install / cleanup_say
###############################################################################

# Run the broker as launchd would (request on stdin, socket = stdout) with
# a stub `say` that records what it was given on stdin. HOME/lock/log are
# pointed under the test tmpdir.
say_broker() {
    make_stub say 'printf "SAY:%s\n" "$(cat)" >> "$STUB_LOG"'
    run bash -c "PATH=\"$STUBS:/usr/bin:/bin\" HOME=\"$BATS_TEST_TMPDIR\" \
        QS_SAY_LOCK=\"$BATS_TEST_TMPDIR/lock\" QS_SAY_LOG=\"$BATS_TEST_TMPDIR/broker.log\" \
        bash \"$REPO_COPY/config/qs-say-broker\" work <<< \"\$1\"" _ "$1"
}

@test "say broker speaks the line it was sent, via stdin, and logs it" {
    say_broker "quicksand is waiting for your input"
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                  # nothing goes back to the client
    grep -qx "SAY:quicksand is waiting for your input" "$STUB_LOG"
    grep -q "quicksand is waiting for your input" "$BATS_TEST_TMPDIR/broker.log"
    [ ! -d "$BATS_TEST_TMPDIR/lock" ]                 # lock released
}

@test "say broker strips control characters and caps the length" {
    say_broker "$(printf 'hi\033]0;pwned\007 there\t!')"
    [ "$status" -eq 0 ]
    grep -qx "SAY:hi]0;pwned there!" "$STUB_LOG"
    say_broker "$(printf 'x%.0s' $(seq 1 400))"
    [ "$status" -eq 0 ]
    # BSD grep caps {n} at 255, so measure the spoken line instead.
    [ "$(awk '/^SAY:x+$/ { print length($0) - 4 }' "$STUB_LOG")" == "300" ]
}

@test "say broker ignores an empty or whitespace-only message" {
    say_broker "   "
    [ "$status" -eq 0 ]
    [ ! -e "$STUB_LOG" ] || ! grep -q "^SAY:" "$STUB_LOG"
}

@test "say broker only ever gives say a single argv-free line" {
    make_stub say 'printf "ARGS:%d\n" "$#" >> "$STUB_LOG"; cat >/dev/null'
    run bash -c "PATH=\"$STUBS:/usr/bin:/bin\" HOME=\"$BATS_TEST_TMPDIR\" \
        QS_SAY_LOCK=\"$BATS_TEST_TMPDIR/lock\" QS_SAY_LOG=\"$BATS_TEST_TMPDIR/broker.log\" \
        bash \"$REPO_COPY/config/qs-say-broker\" work <<< '-v Zarvox --rm -rf'"
    [ "$status" -eq 0 ]
    grep -qx "ARGS:0" "$STUB_LOG"
}

@test "qs-say fails cleanly without a broker socket" {
    run env SHARED_WORKSPACE="$BATS_TEST_TMPDIR/ws" QS_SANDBOX_NAME=work \
        "$REPO_COPY/config/qs-say" hello
    [ "$status" -eq 1 ]
    [[ "$output" == *"broker socket not found"* ]]
    [[ "$output" == *"qs build work --rebuild"* ]]
}

@test "qs-say requires a message" {
    run env QS_SAY_SOCK="$BATS_TEST_TMPDIR/none" "$REPO_COPY/config/qs-say"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage: qs-say"* ]]
}

@test "qs-say delivers one flattened line over the socket" {
    sock="$BATS_TEST_TMPDIR/say.sock"
    # A one-shot listener standing in for launchd + broker; perl's alarm
    # keeps a broken client from hanging the suite.
    perl -e 'alarm 10; exec @ARGV' nc -lU "$sock" > "$BATS_TEST_TMPDIR/got" &
    listener=$!
    for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done
    run perl -e 'alarm 10; exec @ARGV' env QS_SAY_SOCK="$sock" \
        "$REPO_COPY/config/qs-say" "hello" "$(printf 'multi\nline')" "world"
    wait "$listener" || true
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/got")" == "hello multi line world" ]
}

# 30-claude-config against a fake HOME and a workspace with the settings
# template staged; QS_CLAUDE_SETTINGS is the same seam 31-claude-say uses, so
# the suite never touches real settings.
claude_config_fixture() {
    WS="$BATS_TEST_TMPDIR/ws"
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    SETTINGS="$FAKE_HOME/.claude/settings.json"
    mkdir -p "$FAKE_HOME/.claude" "$WS/_quicksand"
    cp "$REPO_COPY/config/claude-settings.json" "$WS/_quicksand/claude-settings.json"
}

run_claude_config() {
    run env HOME="$FAKE_HOME" SHARED_WORKSPACE="$WS" \
        QS_CLAUDE_SETTINGS="$SETTINGS" "$REPO_COPY/profile.d/30-claude-config.sh"
}

@test "config/claude-settings.json is a JSON object that keeps session transcripts" {
    run jq -r 'type + " " + (.cleanupPeriodDays | tostring)' "$REPO_COPY/config/claude-settings.json"
    [ "$output" == "object 3650" ]
    # Hooks are seeded by their own scripts; a top-level merge can't do it.
    run jq -r 'has("hooks")' "$REPO_COPY/config/claude-settings.json"
    [ "$output" == "false" ]
}

@test "30-claude-config seeds a new settings.json from the template" {
    claude_config_fixture
    run_claude_config
    [ "$status" -eq 0 ]
    run jq -S -c . "$SETTINGS"
    [ "$output" == "$(jq -S -c . "$REPO_COPY/config/claude-settings.json")" ]
}

@test "30-claude-config acknowledges bypass mode in settings.json, not ~/.claude.json" {
    claude_config_fixture
    run_claude_config
    [ "$status" -eq 0 ]
    run jq -r '.skipDangerousModePermissionPrompt' "$SETTINGS"
    [ "$output" == "true" ]
    run jq -r '.hasCompletedOnboarding, has("bypassPermissionsModeAccepted")' "$FAKE_HOME/.claude.json"
    [ "$output" == $'true\nfalse' ]
}

@test "30-claude-config adds missing template keys; existing settings win and survive" {
    claude_config_fixture
    echo '{"cleanupPeriodDays":3650,"theme":"dark","model":"sonnet"}' > "$WS/_quicksand/claude-settings.json"
    echo '{"model":"opus","cleanupPeriodDays":7,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/mine.sh"}]}]}}' \
        > "$SETTINGS"
    chmod 0600 "$SETTINGS"
    run_claude_config
    [ "$status" -eq 0 ]
    run jq -c '[.model, .cleanupPeriodDays, .theme, .hooks.Stop[0].hooks[0].command]' "$SETTINGS"
    [ "$output" == '["opus",7,"dark","/x/mine.sh"]' ]
    [ "$(stat -f '%Lp' "$SETTINGS")" == "600" ]
}

@test "30-claude-config leaves settings untouched when no template key is missing" {
    claude_config_fixture
    echo '{"theme":"dark"}' > "$WS/_quicksand/claude-settings.json"
    printf '{ "theme":"light",\n  "mine": 1 }\n' > "$SETTINGS"
    cp "$SETTINGS" "$BATS_TEST_TMPDIR/before"
    run_claude_config
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    cmp "$SETTINGS" "$BATS_TEST_TMPDIR/before"
}

@test "30-claude-config leaves a settings.json that is not a JSON object alone" {
    claude_config_fixture
    echo 'not json' > "$SETTINGS"
    run_claude_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a JSON object"* ]]
    [ "$(cat "$SETTINGS")" == "not json" ]
}

@test "30-claude-config skips the merge when the template is missing or malformed" {
    claude_config_fixture
    rm "$WS/_quicksand/claude-settings.json"
    run_claude_config
    [ "$status" -eq 0 ]
    [ ! -e "$SETTINGS" ]
    echo '["not","an","object"]' > "$WS/_quicksand/claude-settings.json"
    run_claude_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a JSON object"* ]]
    [ ! -e "$SETTINGS" ]
}

# Fixture for the hook: a staged client under a fake workspace, a fake HOME
# for the ~/.local/bin install, and QS_CLAUDE_SETTINGS pointing at a file
# under that HOME (the seam exists so the suite never touches real settings).
say_fixture() {
    WS="$BATS_TEST_TMPDIR/ws"
    FAKE_HOME="$BATS_TEST_TMPDIR/home"
    SETTINGS="$FAKE_HOME/.claude/settings.json"
    mkdir -p "$WS/_quicksand/bin" "$FAKE_HOME"
    cp "$REPO_COPY/config/qs-say" "$WS/_quicksand/bin/qs-say"
}

run_say_hook() {
    run env HOME="$FAKE_HOME" SHARED_WORKSPACE="$WS" QS_CLAUDE_SETTINGS="$SETTINGS" \
        QS_SANDBOX_NAME="${1-work}" "$REPO_COPY/profile.d/31-claude-say.sh"
}

@test "31-claude-say no-ops when no client is staged" {
    say_fixture
    rm "$WS/_quicksand/bin/qs-say"
    run_say_hook
    [ "$status" -eq 0 ]
    [ ! -e "$FAKE_HOME/.local" ]
    [ ! -e "$SETTINGS" ]
}

@test "31-claude-say installs the client and seeds idle + attention Notification hooks, no Stop hook" {
    say_fixture
    run_say_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"once it has been waiting on you"* ]]
    [ -x "$FAKE_HOME/.local/bin/qs-say" ]
    cmp "$REPO_COPY/config/qs-say" "$FAKE_HOME/.local/bin/qs-say"
    run jq -r '.hooks.Notification[0].matcher' "$SETTINGS"
    [ "$output" == "idle_prompt" ]
    run jq -r '.hooks.Notification[0].hooks[0] | .type + " " + .command' "$SETTINGS"
    [ "$output" == "command $FAKE_HOME/.local/bin/qs-say \"work is waiting for your input\"" ]
    run jq -r '.hooks.Notification[1].matcher' "$SETTINGS"
    [ "$output" == "permission_prompt|agent_needs_input" ]
    run jq -r '.hooks.Notification[1].hooks[0].command' "$SETTINGS"
    [ "$output" == "$FAKE_HOME/.local/bin/qs-say \"work needs your attention\"" ]
    # Stop fires after every response, background work or not — never seeded.
    run jq -r '.hooks | has("Stop")' "$SETTINGS"
    [ "$output" == "false" ]
}

@test "31-claude-say falls back to a neutral subject for an unsafe or missing name" {
    say_fixture
    run_say_hook 'bad"; rm -rf /; "'
    [ "$status" -eq 0 ]
    run jq -r '.hooks.Notification[0].hooks[0].command' "$SETTINGS"
    [ "$output" == "$FAKE_HOME/.local/bin/qs-say \"Claude is waiting for your input\"" ]
}

@test "31-claude-say migrates the first-release Stop + combined-Notification shape, keeping the user's hooks" {
    say_fixture
    mkdir -p "$(dirname "$SETTINGS")"
    cat > "$SETTINGS" <<JSON
{"model":"opus","hooks":{
  "Stop":[{"hooks":[{"type":"command","command":"/x/other.sh"}]},
          {"hooks":[{"type":"command","command":"$FAKE_HOME/.local/bin/qs-say \"work is waiting for your input\""}]}],
  "Notification":[{"matcher":"permission_prompt|idle_prompt|agent_needs_input",
                   "hooks":[{"type":"command","command":"$FAKE_HOME/.local/bin/qs-say \"work needs your attention\""}]},
                  {"matcher":"idle_prompt","hooks":[{"type":"command","command":"/x/mine.sh"}]}]}}
JSON
    run_say_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"qs-say hooks updated"* ]]
    run jq -c '.hooks.Stop | map(.hooks[0].command)' "$SETTINGS"
    [ "$output" == '["/x/other.sh"]' ]
    run jq -c '.hooks.Notification | map(.matcher)' "$SETTINGS"
    [ "$output" == '["idle_prompt","idle_prompt","permission_prompt|agent_needs_input"]' ]
    run jq -r '.hooks.Notification[0].hooks[0].command' "$SETTINGS"
    [ "$output" == "/x/mine.sh" ]
    run jq -r '.model' "$SETTINGS"
    [ "$output" == "opus" ]
    # Migration is one-shot: a second run changes nothing.
    cp "$SETTINGS" "$BATS_TEST_TMPDIR/migrated"
    run_say_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    cmp "$SETTINGS" "$BATS_TEST_TMPDIR/migrated"
}

@test "31-claude-say migration drops a qs-say Stop hook even when it was the only Stop entry" {
    say_fixture
    mkdir -p "$(dirname "$SETTINGS")"
    cat > "$SETTINGS" <<JSON
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$FAKE_HOME/.local/bin/qs-say \"work is waiting for your input\""}]}],
          "Notification":[{"matcher":"idle_prompt","hooks":[{"type":"command","command":"$FAKE_HOME/.local/bin/qs-say \"work is waiting for your input\""}]}]}}
JSON
    run_say_hook
    [ "$status" -eq 0 ]
    run jq -r '.hooks | has("Stop")' "$SETTINGS"
    [ "$output" == "false" ]
    run jq -r '.hooks.Notification | length' "$SETTINGS"
    [ "$output" == "1" ]
}

@test "31-claude-say merges into existing settings and hooks" {
    say_fixture
    mkdir -p "$(dirname "$SETTINGS")"
    echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/other.sh"}]}]}}' \
        > "$SETTINGS"
    run_say_hook
    [ "$status" -eq 0 ]
    run jq -r '.model' "$SETTINGS"
    [ "$output" == "opus" ]
    run jq -r '.hooks.Stop | length' "$SETTINGS"
    [ "$output" == "1" ]
    run jq -r '.hooks.Stop[0].hooks[0].command' "$SETTINGS"
    [ "$output" == "/x/other.sh" ]
    run jq -r '.hooks.Notification | length' "$SETTINGS"
    [ "$output" == "2" ]
}

@test "31-claude-say seeds once: reruns add nothing and a deleted entry stays deleted" {
    say_fixture
    run_say_hook
    [ "$status" -eq 0 ]
    cp "$SETTINGS" "$BATS_TEST_TMPDIR/first"
    run_say_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    cmp "$SETTINGS" "$BATS_TEST_TMPDIR/first"
    # The user drops the attention entry but keeps the idle one.
    jq '.hooks.Notification |= map(select(.matcher == "idle_prompt"))' "$SETTINGS" \
        > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    run_say_hook
    [ "$status" -eq 0 ]
    run jq -r '.hooks.Notification | length' "$SETTINGS"
    [ "$output" == "1" ]
}

@test "31-claude-say refreshes an outdated client copy but leaves settings alone" {
    say_fixture
    run_say_hook
    echo "# stale" >> "$FAKE_HOME/.local/bin/qs-say"
    cp "$SETTINGS" "$BATS_TEST_TMPDIR/first"
    run_say_hook
    [ "$status" -eq 0 ]
    cmp "$REPO_COPY/config/qs-say" "$FAKE_HOME/.local/bin/qs-say"
    cmp "$SETTINGS" "$BATS_TEST_TMPDIR/first"
}

@test "31-claude-say leaves a settings file that is not a JSON object untouched" {
    say_fixture
    mkdir -p "$(dirname "$SETTINGS")"
    echo 'not json {' > "$SETTINGS"
    run_say_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"not a JSON object"* ]]
    [ "$(cat "$SETTINGS")" == 'not json {' ]
    [ -x "$FAKE_HOME/.local/bin/qs-say" ]
}

@test "say_broker_install stages, renders, and loads the agent" {
    make_stub launchctl 'echo "launchctl $*" >> "$STUB_LOG"'
    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    qs_run 'PATH="$STUBS:$PATH"; SANDBOX_NAME=work
            SHARED_WORKSPACE="$WORK/ws"; QS_PRIVATE_DIR="$WORK/ws/_quicksand"
            INSTALL_DIR="$WORK/install"
            QS_SAY_LABEL=com.quicksand.say-broker.work
            QS_SAY_PLIST="$WORK/agent.plist"
            QS_SAY_BROKER_STAGED="$WORK/install/say-broker-work.sh"
            HOME="$WORK"
            say_broker_install'
    [ "$status" -eq 0 ]
    [ -x "$WORK/install/say-broker-work.sh" ]
    cmp "$REPO_COPY/config/qs-say-broker" "$WORK/install/say-broker-work.sh"
    [ -x "$WORK/ws/_quicksand/bin/qs-say" ]
    grep -q "<string>com.quicksand.say-broker.work</string>" "$WORK/agent.plist"
    grep -q "<string>$WORK/install/say-broker-work.sh</string>" "$WORK/agent.plist"
    grep -q "<string>work</string>" "$WORK/agent.plist"
    grep -q "$WORK/ws/_quicksand/say.sock" "$WORK/agent.plist"
    grep -q "launchctl bootstrap gui/$(id -u) $WORK/agent.plist" "$STUB_LOG"
}

@test "say_broker_install warns but succeeds when the agent can't be loaded" {
    make_stub launchctl 'case "$1" in bootstrap) exit 1 ;; esac'
    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    qs_run 'PATH="$STUBS:$PATH"; SANDBOX_NAME=work
            SHARED_WORKSPACE="$WORK/ws"; QS_PRIVATE_DIR="$WORK/ws/_quicksand"
            INSTALL_DIR="$WORK/install"
            QS_SAY_LABEL=com.quicksand.say-broker.work
            QS_SAY_PLIST="$WORK/agent.plist"
            QS_SAY_BROKER_STAGED="$WORK/install/say-broker-work.sh"
            HOME="$WORK"
            say_broker_install'
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: Failed to load the speech broker"* ]]
    [ -x "$WORK/ws/_quicksand/bin/qs-say" ]
}

@test "cleanup_say unloads the agent and removes everything it staged" {
    make_stub launchctl 'echo "launchctl $*" >> "$STUB_LOG"'
    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK/install" "$WORK/ws/_quicksand/bin"
    touch "$WORK/agent.plist" "$WORK/install/say-broker-work.sh" \
          "$WORK/install/say-broker-work.log" "$WORK/ws/_quicksand/bin/qs-say"
    qs_run 'PATH="$STUBS:/usr/bin:/bin"; SANDBOX_NAME=work
            QS_PRIVATE_DIR="$WORK/ws/_quicksand"
            INSTALL_DIR="$WORK/install"
            QS_SAY_LABEL=com.quicksand.say-broker.work
            QS_SAY_PLIST="$WORK/agent.plist"
            QS_SAY_BROKER_STAGED="$WORK/install/say-broker-work.sh"
            cleanup_say'
    [ "$status" -eq 0 ]
    grep -q "launchctl bootout gui/$(id -u)/com.quicksand.say-broker.work" "$STUB_LOG"
    [ ! -f "$WORK/agent.plist" ]
    [ ! -f "$WORK/install/say-broker-work.sh" ]
    [ ! -f "$WORK/install/say-broker-work.log" ]
    [ ! -f "$WORK/ws/_quicksand/bin/qs-say" ]
}


###############################################################################
# qs ssh-auth — CLI plumbing and host-side helpers (sudo runs the command
# as-is; sshd, dscl, dseditgroup and launchctl are stubs; root-owned paths
# are redirected under $WORK)
###############################################################################

# Globals the SSH helpers read, pointed at a scratch tree.
SSH_GLOBALS='PATH="$STUBS:$PATH"; SANDBOX_NAME=work; QUICKSAND_USER=qs-work
    HOST_USER=me; COMMAND_ARGS=(); HOME="$WORK/hosthome"
    SHARED_WORKSPACE="$WORK/ws"; SANDBOX_PROFILE="$WORK/var/sandbox-qs-work.sb"
    QS_SSHD_DIR="$WORK/var/ssh-qs-work"
    QS_SSHD_AUTHORIZED_KEYS="$QS_SSHD_DIR/authorized_keys"
    QS_SSHD_SESSION="$QS_SSHD_DIR/session"; QS_SSHD_ZDOTDIR="$QS_SSHD_DIR/zdotdir"
    QS_SSHD_BIN="$STUBS/sshd"; QS_SSHD_CONFIG="$WORK/etc/sshd_config"
    QS_SSHD_DROPIN="$WORK/etc/sshd_config.d/010-quicksand-qs-work.conf"
    QS_SSHD_DEFAULT_DROPIN="$WORK/etc/sshd_config.d/020-quicksand-default.conf"'

ssh_run() {
    qs_run "$SSH_GLOBALS; $1"
}

# A host whose sshd accepts the drop-ins and reports them as effective:
# `sshd -t` succeeds unless $WORK/sshd-t-fails exists, and `sshd -T` prints
# $WORK/effective — or $WORK/effective-default when asked about the probe
# user that stands for "a sandbox without ssh-auth". No Remote Login access
# group exists unless a test creates $WORK/access-group. Two real key pairs
# land in $WORK.
ssh_fixture() {
    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK/etc/sshd_config.d" "$WORK/var" "$WORK/hosthome/.ssh"
    echo "Include $WORK/etc/sshd_config.d/*" > "$WORK/etc/sshd_config"
    make_stub sudo 'while [[ "${1:-}" == -* ]]; do shift; done; exec "$@"'
    make_stub sshd 'echo "sshd $*" >> "$STUB_LOG"
        case " $* " in
            *" -t "*) if [[ -e "$WORK/sshd-t-fails" ]]; then echo "bad config" >&2; exit 255; fi ;;
            *" -T "*"user=qs-.probe,"*) cat "$WORK/effective-default" ;;
            *" -T "*) cat "$WORK/effective" ;;
        esac'
    make_stub dscl '[[ -e "$WORK/access-group" && "$*" == *"/Groups/com.apple.access_ssh" ]]'
    make_stub dseditgroup 'echo "dseditgroup $*" >> "$STUB_LOG"'
    make_stub launchctl 'exit 0'
    make_stub scutil 'echo testmac'
    cat > "$WORK/effective" <<EOF
port 22
forcecommand $WORK/var/ssh-qs-work/session
authorizedkeysfile $WORK/var/ssh-qs-work/authorized_keys
setenv ZDOTDIR=$WORK/var/ssh-qs-work/zdotdir
passwordauthentication no
kbdinteractiveauthentication no
permituserrc no
permituserenvironment no
allowagentforwarding no
EOF
    cat > "$WORK/effective-default" <<EOF
port 22
authorizedkeysfile none
authorizedkeyscommand none
authenticationmethods publickey
passwordauthentication no
kbdinteractiveauthentication no
EOF
    ssh-keygen -q -t ed25519 -N "" -C first@test  -f "$WORK/k1"
    ssh-keygen -q -t ed25519 -N "" -C second@test -f "$WORK/k2"
}

@test "parse_args accepts 'ssh-auth NAME' with an optional key or 'off'" {
    qs_run 'parse_args ssh-auth work; echo "$COMMAND|$SANDBOX_NAME|$SSH_AUTH_ARG"'
    [ "$status" -eq 0 ]
    [[ "$output" == "ssh-auth|work|" ]]
    qs_run 'parse_args sa work off; echo "$COMMAND|$SSH_AUTH_ARG"'
    [[ "$output" == "ssh-auth|off" ]]
    qs_run 'parse_args ssh-auth work /tmp/key.pub; echo "$SSH_AUTH_ARG"'
    [[ "$output" == "/tmp/key.pub" ]]
}

@test "parse_args rejects an unquoted key line for ssh-auth" {
    qs_run 'parse_args ssh-auth work ssh-ed25519 AAAA me@host'
    [ "$status" -ne 0 ]
    [[ "$output" == *"quote a pasted key line"* ]]
}

@test "help lists the ssh-auth command" {
    run "$QS" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"qs ssh-auth  NAME [KEY.pub | off]"* ]]
}

@test "config_fingerprint changes when the SSH session wrapper or sshd template changes" {
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    before="$output"
    echo "# changed" >> "$REPO_COPY/config/qs-ssh-session"
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    middle="$output"
    [ "$before" != "$middle" ]
    echo "# changed" >> "$REPO_COPY/config/sshd-quicksand.conf.tmpl"
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    [ "$middle" != "$output" ]
}

@test "ssh_access_install installs the wrapper, key file and verified sshd drop-in" {
    ssh_fixture
    ssh_run 'ssh_access_install'
    [ "$status" -eq 0 ]
    dropin="$WORK/etc/sshd_config.d/010-quicksand-qs-work.conf"
    grep -qx "Match User qs-work" "$dropin"
    grep -qx "    ForceCommand $WORK/var/ssh-qs-work/session" "$dropin"
    grep -qx "    AuthorizedKeysFile $WORK/var/ssh-qs-work/authorized_keys" "$dropin"
    grep -qx "    SetEnv ZDOTDIR=$WORK/var/ssh-qs-work/zdotdir" "$dropin"
    # Nothing a sandbox can write may be trusted by sshd.
    [ "$(/usr/bin/stat -f %Lp "$WORK/var/ssh-qs-work/session")" == "555" ]
    [ "$(/usr/bin/stat -f %Lp "$WORK/var/ssh-qs-work/authorized_keys")" == "644" ]
    [ "$(/usr/bin/stat -f %Lp "$WORK/var/ssh-qs-work")" == "755" ]
    [ -d "$WORK/var/ssh-qs-work/zdotdir" ]
    [ -z "$(ls -A "$WORK/var/ssh-qs-work/zdotdir")" ]
    # Every template token was substituted.
    ! grep -qE '@[A-Z_]+@' "$dropin" "$WORK/var/ssh-qs-work/session"
    grep -q 'readonly QS_USER="qs-work"' "$WORK/var/ssh-qs-work/session"
    grep -q "readonly QS_PROFILE=\"$WORK/var/sandbox-qs-work.sb\"" "$WORK/var/ssh-qs-work/session"
    grep -q "sshd -t -f $WORK/etc/sshd_config" "$STUB_LOG"
    grep -q "sshd -T -f $WORK/etc/sshd_config -C user=qs-work," "$STUB_LOG"
    ! grep -q dseditgroup "$STUB_LOG"
}

@test "ssh_access_install keeps authorized keys across a refresh" {
    ssh_fixture
    ssh_run 'ssh_access_install; ssh_read_keys "$WORK/k1.pub"; ssh_append_keys; ssh_access_install'
    [ "$status" -eq 0 ]
    grep -qF "$(cat "$WORK/k1.pub")" "$WORK/var/ssh-qs-work/authorized_keys"
}

@test "ssh_access_install removes the drop-in again when sshd rejects the config" {
    ssh_fixture
    touch "$WORK/sshd-t-fails"
    ssh_run 'ssh_access_install'
    [ "$status" -ne 0 ]
    [[ "$output" == *"sshd rejected its configuration"*"bad config"* ]]
    [ ! -e "$WORK/etc/sshd_config.d/010-quicksand-qs-work.conf" ]
}

@test "ssh_access_install removes the drop-in when its settings would be shadowed" {
    ssh_fixture
    sed -i '' -e 's|^forcecommand .*|forcecommand none|' "$WORK/effective"
    ssh_run 'ssh_access_install'
    [ "$status" -ne 0 ]
    [[ "$output" == *"would not apply 'forcecommand $WORK/var/ssh-qs-work/session'"* ]]
    [ ! -e "$WORK/etc/sshd_config.d/010-quicksand-qs-work.conf" ]
}

@test "ssh_access_install refuses a host that lets users set their own environment" {
    ssh_fixture
    sed -i '' -e 's|^permituserenvironment no|permituserenvironment yes|' "$WORK/effective"
    ssh_run 'ssh_access_install'
    [ "$status" -ne 0 ]
    [[ "$output" == *"would not apply 'permituserenvironment no'"* ]]
    [ ! -e "$WORK/etc/sshd_config.d/010-quicksand-qs-work.conf" ]
}

@test "ssh_access_install changes nothing when sshd_config has no drop-in Include" {
    ssh_fixture
    echo "Port 22" > "$WORK/etc/sshd_config"
    ssh_run 'ssh_access_install'
    [ "$status" -ne 0 ]
    [[ "$output" == *"doesn't include $WORK/etc/sshd_config.d/"* ]]
    [ ! -e "$WORK/var/ssh-qs-work" ]
    [ -z "$(ls -A "$WORK/etc/sshd_config.d")" ]
}

@test "ssh_access_install joins the Remote Login access group when one exists" {
    ssh_fixture
    touch "$WORK/access-group"
    ssh_run 'ssh_access_install'
    [ "$status" -eq 0 ]
    grep -qx "dseditgroup -o edit -a qs-work -t user com.apple.access_ssh" "$STUB_LOG"
}

@test "ssh_default_deny_install installs the shared rule and checks it against a non-sandbox name" {
    ssh_fixture
    ssh_run 'ssh_default_deny_install'
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARNING"* ]]
    dropin="$WORK/etc/sshd_config.d/020-quicksand-default.conf"
    cmp "$REPO_COPY/config/sshd-quicksand-default.conf" "$dropin"
    grep -qx "Match User qs-\*" "$dropin"
    grep -qx "    AuthorizedKeysFile none" "$dropin"
    [ "$(/usr/bin/stat -f %Lp "$dropin")" == "644" ]
    grep -q "sshd -t -f $WORK/etc/sshd_config" "$STUB_LOG"
    grep -q "sshd -T -f $WORK/etc/sshd_config -C user=qs-.probe," "$STUB_LOG"
}

@test "the shared rule sorts after every per-sandbox drop-in, so ssh-auth keys win" {
    qs_run 'SANDBOX_NAME=zzzzzzzzzzzzzzzz; INITIAL_DIR=/tmp; QS_CUSTOM_DIR=/nonexistent
            HOME="$BATS_TEST_TMPDIR"; USER=me; derive_constants
            printf "%s\n" "$QS_SSHD_DEFAULT_DROPIN" "$QS_SSHD_DROPIN" | LC_ALL=C sort | head -n1
            echo "$QS_SSHD_DROPIN"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "${lines[1]}" ]
    [ "$(dirname "${lines[0]}")" == "/etc/ssh/sshd_config.d" ]
}

@test "ssh_default_deny_install warns and removes the rule when sshd rejects the config" {
    ssh_fixture
    touch "$WORK/sshd-t-fails"
    ssh_run 'ssh_default_deny_install; echo "build-continues"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: sshd rejected its configuration"*"bad config"* ]]
    [[ "$output" == *"build-continues"* ]]
    [ ! -e "$WORK/etc/sshd_config.d/020-quicksand-default.conf" ]
}

@test "ssh_default_deny_install warns and removes the rule when it would be shadowed" {
    ssh_fixture
    sed -i '' -e 's|^authorizedkeysfile none|authorizedkeysfile .ssh/authorized_keys|' "$WORK/effective-default"
    ssh_run 'ssh_default_deny_install; echo "build-continues"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: sshd would not apply 'authorizedkeysfile none' to sandbox users"* ]]
    [[ "$output" == *"build-continues"* ]]
    [ ! -e "$WORK/etc/sshd_config.d/020-quicksand-default.conf" ]
}

@test "ssh_default_deny_install warns and installs nothing without a drop-in Include" {
    ssh_fixture
    echo "Port 22" > "$WORK/etc/sshd_config"
    ssh_run 'ssh_default_deny_install; echo "build-continues"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: $WORK/etc/sshd_config doesn't include"* ]]
    [[ "$output" == *"build-continues"* ]]
    [ -z "$(ls -A "$WORK/etc/sshd_config.d")" ]
}

@test "ssh_default_deny_cleanup keeps the rule while any sandbox remains" {
    ssh_fixture
    ssh_run 'ssh_default_deny_install
             touch "$WORK/var/sandbox-qs-other.sb"; ssh_default_deny_cleanup'
    [ "$status" -eq 0 ]
    [ -e "$WORK/etc/sshd_config.d/020-quicksand-default.conf" ]
    ssh_run 'rm "$WORK/var/sandbox-qs-other.sb"; ssh_default_deny_cleanup'
    [ "$status" -eq 0 ]
    [ ! -e "$WORK/etc/sshd_config.d/020-quicksand-default.conf" ]
}

@test "config_fingerprint changes when the default SSH rule changes" {
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    before="$output"
    echo "# changed" >> "$REPO_COPY/config/sshd-quicksand-default.conf"
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    [ "$before" != "$output" ]
}

@test "ssh keys are appended once, compared by key rather than comment" {
    ssh_fixture
    awk '{print $1, $2, "renamed@elsewhere"}' "$WORK/k1.pub" > "$WORK/k1-renamed.pub"
    ssh_run 'ssh_access_install
             ssh_read_keys "$WORK/k1.pub"; ssh_append_keys
             ssh_read_keys "$WORK/k1-renamed.pub"; ssh_append_keys
             ssh_read_keys "$(cat "$WORK/k2.pub")"; ssh_append_keys
             ssh_key_count'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Authorized: 256 SHA256:"*"first@test"* ]]
    [[ "$output" == *"Already authorized:"* ]]
    [ "${lines[${#lines[@]}-1]}" == "2" ]
    [ "$(wc -l < "$WORK/var/ssh-qs-work/authorized_keys" | tr -d ' ')" == "2" ]
    grep -qF "second@test" "$WORK/var/ssh-qs-work/authorized_keys"
}

@test "ssh_read_keys refuses a private key without echoing it" {
    ssh_fixture
    ssh_run 'ssh_read_keys "$WORK/k1"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not an OpenSSH public key file"* ]]
    [[ "$output" != *"BEGIN OPENSSH PRIVATE KEY"* ]]
}

@test "ssh_read_keys refuses key lines that carry authorized_keys options" {
    ssh_fixture
    printf 'command="/bin/sh" %s\n' "$(cat "$WORK/k1.pub")" > "$WORK/opts.pub"
    ssh_run 'ssh_read_keys "$WORK/opts.pub"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not an OpenSSH public key file"* ]]
}

@test "ssh_read_keys refuses an argument that is neither a file nor a key" {
    ssh_fixture
    ssh_run 'ssh_read_keys "$WORK/nope.pub"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Expected a public key file or a quoted public key line"* ]]
    ssh_run 'ssh_read_keys "ssh-ed25519 not_base64!"'
    [ "$status" -ne 0 ]
}

@test "cmd_ssh_auth authorizes the host user's own key by default" {
    ssh_fixture
    cp "$WORK/k1.pub" "$WORK/hosthome/.ssh/id_ed25519.pub"
    ssh_run 'SSH_AUTH_ARG=""; cmd_ssh_auth'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSH access enabled for 'work'"* ]]
    [[ "$output" == *"ssh qs-work@testmac.local"* ]]
    [[ "$output" == *"1 authorized"* ]]
    [[ "$output" != *"WARNING"* ]]
    grep -qF "$(cat "$WORK/k1.pub")" "$WORK/var/ssh-qs-work/authorized_keys"
}

@test "cmd_ssh_auth with no argument only refreshes once keys exist" {
    ssh_fixture
    cp "$WORK/k1.pub" "$WORK/hosthome/.ssh/id_ed25519.pub"
    ssh_run 'SSH_AUTH_ARG="$WORK/k2.pub"; cmd_ssh_auth; SSH_AUTH_ARG=""; cmd_ssh_auth'
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$WORK/var/ssh-qs-work/authorized_keys" | tr -d ' ')" == "1" ]
    grep -qF "second@test" "$WORK/var/ssh-qs-work/authorized_keys"
}

@test "cmd_ssh_auth installs nothing when there is no key to authorize" {
    ssh_fixture
    ssh_run 'SSH_AUTH_ARG=""; cmd_ssh_auth'
    [ "$status" -ne 0 ]
    [[ "$output" == *"No public key to authorize"* ]]
    [ ! -e "$WORK/var/ssh-qs-work" ]
    ssh_run 'SSH_AUTH_ARG="$WORK/k1"; cmd_ssh_auth'
    [ "$status" -ne 0 ]
    [ ! -e "$WORK/var/ssh-qs-work" ]
    [ -z "$(ls -A "$WORK/etc/sshd_config.d")" ]
}

@test "cmd_ssh_auth warns when Remote Login is off" {
    ssh_fixture
    make_stub launchctl 'exit 113'
    ssh_run 'SSH_AUTH_ARG="$WORK/k1.pub"; cmd_ssh_auth'
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: Remote Login is off"* ]]
}

@test "cmd_ssh_auth off revokes the keys and removes the sshd configuration" {
    ssh_fixture
    ssh_run 'SSH_AUTH_ARG="$WORK/k1.pub"; cmd_ssh_auth; SSH_AUTH_ARG=off; cmd_ssh_auth'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSH access disabled for 'work'"* ]]
    [ ! -e "$WORK/etc/sshd_config.d/010-quicksand-qs-work.conf" ]
    [ ! -e "$WORK/var/ssh-qs-work" ]
    grep -qx "dseditgroup -o edit -d qs-work -t user com.apple.access_ssh" "$STUB_LOG"
}


###############################################################################
# config/qs-ssh-session — the rendered wrapper run directly, as sshd would,
# with sandbox-exec swapped for a stub that logs and execs the rest
###############################################################################

# Render the wrapper for the current user (it refuses to serve anyone else)
# against a scratch home, workspace and sandbox profile. $1 overrides the user.
session_fixture() {
    export WORK="$BATS_TEST_TMPDIR/work"
    export SESSION="$WORK/session"
    mkdir -p "$WORK/home" "$WORK/ws/_quicksand/profile.d" "$WORK/ws/_quicksand/logout.d"
    touch "$WORK/profile.sb"
    # The log path is baked in: the wrapper scrubs the environment, so the
    # stub can't read $STUB_LOG from it.
    make_stub sandbox-exec "echo \"sandbox-exec \$1 \$2\" >> \"$STUB_LOG\"; shift 2; exec \"\$@\""
    sed -e "s|@SANDBOX_NAME@|work|g" \
        -e "s|@QUICKSAND_USER@|${1:-$(id -un)}|g" \
        -e "s|@QUICKSAND_USER_HOME@|$WORK/home|g" \
        -e "s|@SHARED_WORKSPACE@|$WORK/ws|g" \
        -e "s|@SANDBOX_PROFILE@|$WORK/profile.sb|g" \
        -e "s|@HOST_USER@|me|g" \
        -e "s|/usr/bin/sandbox-exec|$STUBS/sandbox-exec|g" \
        "$REPO_COPY/config/qs-ssh-session" > "$SESSION"
    chmod +x "$SESSION"
}

# session_hook DIR NAME BODY — add an executable hook to profile.d/logout.d.
session_hook() {
    printf '#!/bin/bash\n%s\n' "$3" > "$WORK/ws/_quicksand/$1/$2"
    chmod +x "$WORK/ws/_quicksand/$1/$2"
}

@test "ssh session runs the client's command inside sandbox-exec" {
    session_fixture
    export SSH_ORIGINAL_COMMAND='echo "ran in $QS_SANDBOX_NAME at $PWD as $QS_HOST_USER"'
    run bash -c '"$SESSION" </dev/null 2>/dev/null'
    [ "$status" -eq 0 ]
    [[ "$output" == "ran in work at $WORK/home as me" ]]
    grep -qx "sandbox-exec -f $WORK/profile.sb" "$STUB_LOG"
}

@test "ssh session passes the command's exit status through" {
    session_fixture
    export SSH_ORIGINAL_COMMAND='exit 7'
    run bash -c '"$SESSION" </dev/null 2>/dev/null'
    [ "$status" -eq 7 ]
}

@test "ssh session builds a scrubbed environment" {
    session_fixture
    export LEAKED=from-sshd SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22"
    export SSH_ORIGINAL_COMMAND='echo "leak=[${LEAKED:-}] sid=${QS_SESSION_ID:+set} lang=$LANG conn=$SSH_CONNECTION shell=$SHELL path=$PATH"'
    run bash -c 'unset LANG; "$SESSION" </dev/null 2>/dev/null'
    [ "$status" -eq 0 ]
    [[ "$output" == "leak=[] sid=set lang=en_US.UTF-8 conn=1.2.3.4 5 6.7.8.9 22 shell=/bin/zsh path=$WORK/home/.local/bin:$WORK/home/.claude/local:/usr/bin:/bin:/usr/sbin:/sbin" ]]
}

@test "ssh session keeps hook output and hook stdin away from the command's streams" {
    session_fixture
    session_hook profile.d 10-noisy.sh 'echo profile-noise; cat'
    session_hook logout.d 10-bye.sh 'echo logout-noise; touch "$SHARED_WORKSPACE/logged-out"'
    echo 'echo zshrc-noise; export FROM_ZSHRC=yes' > "$WORK/home/.zshrc"
    export SSH_ORIGINAL_COMMAND='cat; echo " zshrc=$FROM_ZSHRC"'
    run bash -c 'printf payload | "$SESSION" 2>"$WORK/stderr"'
    [ "$status" -eq 0 ]
    [[ "$output" == "payload zshrc=yes" ]]
    grep -qx "profile-noise" "$WORK/stderr"
    grep -qx "zshrc-noise" "$WORK/stderr"
    grep -qx "logout-noise" "$WORK/stderr"
    [ -e "$WORK/ws/logged-out" ]
}

@test "ssh session without a command runs piped stdin as a shell" {
    session_fixture
    unset SSH_ORIGINAL_COMMAND
    run bash -c 'echo "echo piped-into-\$QS_SANDBOX_NAME" | "$SESSION" 2>/dev/null'
    [ "$status" -eq 0 ]
    [[ "$output" == "piped-into-work" ]]
}

@test "ssh session fails closed when the sandbox profile is missing" {
    session_fixture
    rm "$WORK/profile.sb"
    export SSH_ORIGINAL_COMMAND='echo should-not-run'
    run bash -c '"$SESSION" </dev/null'
    [ "$status" -ne 0 ]
    [[ "$output" == *"sandbox profile $WORK/profile.sb is missing"* ]]
    [[ "$output" != *"should-not-run"* ]]
    [ ! -e "$STUB_LOG" ]
}

@test "ssh session refuses to serve any user but its own" {
    session_fixture qs-someone-else
    export SSH_ORIGINAL_COMMAND='echo should-not-run'
    run bash -c '"$SESSION" </dev/null'
    [ "$status" -ne 0 ]
    [[ "$output" == *"only serves qs-someone-else"* ]]
    [[ "$output" != *"should-not-run"* ]]
}


###############################################################################
# credential broker — config/qs-auth-broker run directly (stdin/stdout stand
# in for the client socket) against a directory of stub providers
###############################################################################

# auth_fixture — a libexec dir of stub providers under $WORK. Each test adds
# the providers it needs with auth_provider NAME BODY.
auth_fixture() {
    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK/libexec" "$WORK/priv" "$WORK/install"
}

auth_provider() {
    printf '#!/bin/bash\n%s\n' "$2" > "$WORK/libexec/qs-auth-$1"
    chmod +x "$WORK/libexec/qs-auth-$1"
}

# run_auth_broker REQUEST — one broker invocation, as launchd would spawn it.
run_auth_broker() {
    run env QS_AUTH_LIBEXEC="$WORK/libexec" QS_AUTH_PRIVATE_DIR="$WORK/priv" \
            QS_AUTH_INSTALL_DIR="$WORK/install" QS_AUTH_LOG="$WORK/broker.log" \
            QS_AUTH_LOCK="$WORK/lock" QS_AUTH_PROVIDER_TIMEOUT="${AUTH_TIMEOUT:-10}" \
            bash -c 'printf "%s\n" "$1" | "$REPO_COPY/config/qs-auth-broker" work' _ "$1"
}

@test "auth broker runs every provider's refresh with the qs environment contract" {
    auth_fixture
    auth_provider one 'echo "$1 $QS_SANDBOX_NAME $QS_PRIVATE_DIR $QS_INSTALL_DIR" > "$QS_PRIVATE_DIR/one"'
    auth_provider two 'echo "$1" > "$QS_PRIVATE_DIR/two"'
    run_auth_broker refresh
    [ "$status" -eq 0 ]
    [ "$output" == "done" ]
    [ "$(cat "$WORK/priv/one")" == "refresh work $WORK/priv $WORK/install" ]
    [ "$(cat "$WORK/priv/two")" == "refresh" ]
    [ ! -d "$WORK/lock" ]
}

@test "auth broker relays provider messages and still completes when one fails" {
    auth_fixture
    auth_provider aaa 'echo "WARNING: unlock 1Password" >&2; exit 3'
    auth_provider bbb 'echo "Refreshing GCP access token..."'
    run_auth_broker refresh
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "WARNING: unlock 1Password" ]
    [ "${lines[1]}" == "Refreshing GCP access token..." ]
    [ "${lines[2]}" == "done" ]
    grep -q "aaa: refresh exit 3" "$WORK/broker.log"
}

@test "auth broker accepts no request but 'refresh'" {
    auth_fixture
    auth_provider one 'touch "$QS_PRIVATE_DIR/ran"'
    run_auth_broker 'refresh; rm -rf /'
    [ "$status" -eq 0 ]
    [[ "$output" == *"unknown request"* ]]
    [[ "$output" != *"done"* ]]
    [ ! -e "$WORK/priv/ran" ]
    run_auth_broker 'provision'
    [[ "$output" != *"done"* ]]
    [ ! -e "$WORK/priv/ran" ]
}

@test "auth broker gives up on a provider that blocks, and says so" {
    auth_fixture
    auth_provider slow 'sleep 30'
    auth_provider next 'touch "$QS_PRIVATE_DIR/next-ran"'
    AUTH_TIMEOUT=1 run_auth_broker refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"slow credential refresh gave up after 1s"* ]]
    [ "${lines[${#lines[@]}-1]}" == "done" ]
    [ -e "$WORK/priv/next-ran" ]
    ! pgrep -f "$WORK/libexec/qs-auth-slow"
}

@test "auth broker reuses a refresh that was already in flight" {
    auth_fixture
    auth_provider one 'touch "$QS_PRIVATE_DIR/ran"'
    mkdir "$WORK/lock"
    ( sleep 1; rmdir "$WORK/lock" ) &
    run_auth_broker refresh
    wait
    [ "$status" -eq 0 ]
    [ "$output" == "done" ]
    [ ! -e "$WORK/priv/ran" ]
    grep -q "shared with a concurrent request" "$WORK/broker.log"
}

@test "auth broker reports a missing provider directory instead of claiming success" {
    auth_fixture
    rmdir "$WORK/libexec"
    run_auth_broker refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"auth providers were not found on the host"* ]]
    [[ "$output" != *"done"* ]]
}

@test "qs-auth-refresh talks to the broker over the socket and reports its messages" {
    auth_fixture
    auth_provider one 'echo "WARNING: unlock 1Password"; touch "$QS_PRIVATE_DIR/ran"'
    # Unix socket paths are capped at ~104 bytes; bats' temp paths are longer.
    SOCK_DIR="$(mktemp -d /tmp/qs-auth.XXXXXX)"
    mkfifo "$SOCK_DIR/back"
    ( nc -lU "$SOCK_DIR/s" < "$SOCK_DIR/back" \
        | env QS_AUTH_LIBEXEC="$WORK/libexec" QS_AUTH_PRIVATE_DIR="$WORK/priv" \
              QS_AUTH_INSTALL_DIR="$WORK/install" QS_AUTH_LOG="$WORK/broker.log" \
              QS_AUTH_LOCK="$WORK/lock" "$REPO_COPY/config/qs-auth-broker" work \
        > "$SOCK_DIR/back" ) &
    for _ in $(seq 1 50); do [ -S "$SOCK_DIR/s" ] && break; sleep 0.1; done
    QS_AUTH_SOCK="$SOCK_DIR/s" QS_AUTH_REFRESH_TIMEOUT=10 run "$REPO_COPY/config/qs-auth-refresh"
    wait
    rm -rf "$SOCK_DIR"
    [ "$status" -eq 0 ]
    [ "$output" == "quicksand: WARNING: unlock 1Password" ]
    [ -e "$WORK/priv/ran" ]
}

@test "qs-auth-refresh fails clearly when there is no broker socket" {
    QS_AUTH_SOCK="$BATS_TEST_TMPDIR/nope.sock" QS_SANDBOX_NAME=work run "$REPO_COPY/config/qs-auth-refresh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"broker socket not found"*"qs build work --rebuild"* ]]
}

@test "auth_broker_install stages, renders, and loads the agent" {
    make_stub launchctl 'echo "launchctl $*" >> "$STUB_LOG"'
    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    qs_run 'PATH="$STUBS:/opt/a&b/bin:/usr/bin:/bin"; SANDBOX_NAME=work
            SHARED_WORKSPACE="$WORK/ws"; QS_PRIVATE_DIR="$WORK/ws/_quicksand"
            INSTALL_DIR="$WORK/install"
            QS_AUTH_LABEL=com.quicksand.auth-broker.work
            QS_AUTH_PLIST="$WORK/agent.plist"
            QS_AUTH_BROKER_STAGED="$WORK/install/auth-broker-work.sh"
            HOME="$WORK"
            auth_broker_install'
    [ "$status" -eq 0 ]
    cmp "$REPO_COPY/config/qs-auth-broker" "$WORK/install/auth-broker-work.sh"
    [ -x "$WORK/ws/_quicksand/bin/qs-auth-refresh" ]
    grep -q "<string>com.quicksand.auth-broker.work</string>" "$WORK/agent.plist"
    grep -q "<string>$WORK/install/auth-broker-work.sh</string>" "$WORK/agent.plist"
    # qs resolves its own location through symlinks (pwd -P).
    grep -q "<string>$(cd "$REPO_COPY" && pwd -P)/libexec</string>" "$WORK/agent.plist"
    grep -q "<string>$WORK/ws/_quicksand/auth.sock</string>" "$WORK/agent.plist"
    # The build shell's PATH is pinned, XML-escaped.
    grep -qF "<string>$STUBS:/opt/a&amp;b/bin:/usr/bin:/bin</string>" "$WORK/agent.plist"
    ! grep -qE '@[A-Z_]+@' "$WORK/agent.plist"
    plutil -lint "$WORK/agent.plist"
    grep -q "launchctl bootstrap gui/$(id -u) $WORK/agent.plist" "$STUB_LOG"
}

@test "auth_broker_install warns but succeeds when the agent can't be loaded" {
    make_stub launchctl 'case "$1" in bootstrap) exit 1 ;; esac'
    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    qs_run 'PATH="$STUBS:$PATH"; SANDBOX_NAME=work
            SHARED_WORKSPACE="$WORK/ws"; QS_PRIVATE_DIR="$WORK/ws/_quicksand"
            INSTALL_DIR="$WORK/install"
            QS_AUTH_LABEL=com.quicksand.auth-broker.work
            QS_AUTH_PLIST="$WORK/agent.plist"
            QS_AUTH_BROKER_STAGED="$WORK/install/auth-broker-work.sh"
            HOME="$WORK"
            auth_broker_install'
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: Failed to load the credential broker"* ]]
    [ -x "$WORK/ws/_quicksand/bin/qs-auth-refresh" ]
}

@test "cleanup_auth_broker unloads the agent and removes everything it staged" {
    make_stub launchctl 'echo "launchctl $*" >> "$STUB_LOG"'
    export WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK/install" "$WORK/ws/_quicksand/bin"
    touch "$WORK/agent.plist" "$WORK/install/auth-broker-work.sh" \
          "$WORK/install/auth-broker-work.log" "$WORK/ws/_quicksand/bin/qs-auth-refresh"
    qs_run 'PATH="$STUBS:/usr/bin:/bin"; SANDBOX_NAME=work
            QS_PRIVATE_DIR="$WORK/ws/_quicksand"
            INSTALL_DIR="$WORK/install"
            QS_AUTH_LABEL=com.quicksand.auth-broker.work
            QS_AUTH_PLIST="$WORK/agent.plist"
            QS_AUTH_BROKER_STAGED="$WORK/install/auth-broker-work.sh"
            cleanup_auth_broker'
    [ "$status" -eq 0 ]
    grep -q "launchctl bootout gui/$(id -u)/com.quicksand.auth-broker.work" "$STUB_LOG"
    [ ! -f "$WORK/agent.plist" ]
    [ ! -f "$WORK/install/auth-broker-work.sh" ]
    [ ! -f "$WORK/install/auth-broker-work.log" ]
    [ ! -f "$WORK/ws/_quicksand/bin/qs-auth-refresh" ]
}

@test "config_fingerprint changes when the credential broker changes" {
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    before="$output"
    echo "# changed" >> "$REPO_COPY/config/qs-auth-broker"
    qs_run 'QS_CUSTOM_DIR=/nonexistent; config_fingerprint'
    [ "$before" != "$output" ]
}


###############################################################################
# session hooks around the broker — 05-session-register, 11-auth-refresh and
# the last-session-out rule in logout.d/15-op-token
###############################################################################

# hooks_fixture — a workspace and home under $WORK with a staged client that
# records each call instead of reaching for a socket.
hooks_fixture() {
    export WORK="$BATS_TEST_TMPDIR/work"
    export SHARED_WORKSPACE="$WORK/ws" HOME="$WORK/home"
    mkdir -p "$WORK/ws/_quicksand/bin" "$WORK/home"
    printf '#!/bin/bash\necho called >> "%s"\n' "$WORK/refresh-calls" \
        > "$WORK/ws/_quicksand/bin/qs-auth-refresh"
    echo "ops_token" > "$WORK/ws/_quicksand/op-token"
}

@test "11-auth-refresh installs the client and leaves local sessions alone" {
    hooks_fixture
    unset SSH_CONNECTION
    run "$REPO_COPY/profile.d/11-auth-refresh.sh"
    [ "$status" -eq 0 ]
    [ -x "$WORK/home/.local/bin/qs-auth-refresh" ]
    cmp "$WORK/ws/_quicksand/bin/qs-auth-refresh" "$WORK/home/.local/bin/qs-auth-refresh"
    [ ! -e "$WORK/refresh-calls" ]
}

@test "11-auth-refresh asks the host for credentials in an SSH session" {
    hooks_fixture
    SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22" run "$REPO_COPY/profile.d/11-auth-refresh.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$WORK/refresh-calls")" == "called" ]
}

@test "11-auth-refresh never fails the session when the host can't answer" {
    hooks_fixture
    printf '#!/bin/bash\necho "broker down" >&2; exit 1\n' > "$WORK/ws/_quicksand/bin/qs-auth-refresh"
    SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22" run "$REPO_COPY/profile.d/11-auth-refresh.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"broker down"* ]]
}

@test "11-auth-refresh does nothing when the build staged no client" {
    hooks_fixture
    rm "$WORK/ws/_quicksand/bin/qs-auth-refresh"
    SSH_CONNECTION="1.2.3.4 5 6.7.8.9 22" run "$REPO_COPY/profile.d/11-auth-refresh.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$WORK/home/.local/bin/qs-auth-refresh" ]
}

@test "the op token survives a session ending while another is still running" {
    hooks_fixture
    # Each hook's parent is its session shell, so two long-lived shells play
    # two sessions: both register, the first logs out.
    run bash -c '
        bash -c "\"$REPO_COPY/profile.d/05-session-register.sh\"; exec sleep 30" &
        other=$!
        for _ in $(seq 1 50); do [ -e "$SHARED_WORKSPACE/_quicksand/sessions/$other" ] && break; sleep 0.1; done
        bash -c "\"$REPO_COPY/profile.d/05-session-register.sh\"; \"$REPO_COPY/logout.d/15-op-token.sh\"; exit 0"
        ls "$SHARED_WORKSPACE/_quicksand/sessions" | wc -l | tr -d " "
        [ -e "$SHARED_WORKSPACE/_quicksand/op-token" ] && echo kept
        kill $other'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "1" ]
    [ "${lines[1]}" == "kept" ]
}

@test "the op token is removed when the last session ends, pruning dead records" {
    hooks_fixture
    mkdir -p "$WORK/ws/_quicksand/sessions"
    # A record whose process is long gone (a session that was SIGHUP'd).
    bash -c 'echo $$' > "$WORK/dead-pid"
    touch "$WORK/ws/_quicksand/sessions/$(cat "$WORK/dead-pid")"
    run bash -c '"$REPO_COPY/profile.d/05-session-register.sh"; "$REPO_COPY/logout.d/15-op-token.sh"; exit 0'
    [ "$status" -eq 0 ]
    [ ! -e "$WORK/ws/_quicksand/op-token" ]
    [ -z "$(ls -A "$WORK/ws/_quicksand/sessions")" ]
}
