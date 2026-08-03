#!/usr/bin/env bats
# Unit tests for qs. Each test sources a private copy of the repo (so
# fingerprint tests can mutate profile.d/ etc.) and calls functions
# directly with controlled globals; external commands are stubbed via
# PATH where needed. Nothing here touches sudo or real sandboxes.

setup() {
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
