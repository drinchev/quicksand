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
    QS="$REPO_COPY/qs"
    STUBS="$BATS_TEST_TMPDIR/stubs"
    STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$STUBS"
    export QS STUBS STUB_LOG
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
            do_clone'
    [ "$status" -eq 0 ]
    grep -q "git clone git@github.com:me/proj.git" "$STUB_LOG"
    grep -q "deploy-key add" "$STUB_LOG"
    grep -q "$(printf 'proj\tme/proj\t')" "$MANIFEST"
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
            do_clone'
    [ "$status" -eq 0 ]
    local esc
    esc="$(printf '%q' "$BATS_TEST_TMPDIR/ws dir/.ssh/id_ed25519_proj")"
    grep -qF "ssh -i $esc" "$STUB_LOG"
}


###############################################################################
# gh token integration
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

@test "url_encode percent-encodes reserved characters" {
    qs_run 'url_encode "qs:demo:my repo"'
    [[ "$output" == "qs%3Ademo%3Amy%20repo" ]]
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

@test "gh_token_setup is a no-op on non-interactive stdin" {
    qs_run 'QS_PRIVATE_DIR="$BATS_TEST_TMPDIR/priv" SANDBOX_NAME=demo
            gh_token_setup owner repo repo < /dev/null
            ls "$BATS_TEST_TMPDIR/priv" 2>/dev/null || echo no-file'
    [ "$status" -eq 0 ]
    [[ "$output" == *"no-file"* ]]
}

@test "cmd_gh_auth requires a repo when none can be detected" {
    qs_run 'COMMAND_ARGS=(); GH_AUTH_REPO=""; SANDBOX_NAME=demo
            QS_CLONES_MANIFEST="$BATS_TEST_TMPDIR/none"
            cmd_gh_auth'
    [ "$status" -ne 0 ]
    [[ "$output" == *"Specify which repo"* ]]
}

@test "cleanup reminds about a saved gh token that can't be API-revoked" {
    make_stub gh 'exit 0'
    export MANIFEST="$BATS_TEST_TMPDIR/manifest"
    export PRIV="$BATS_TEST_TMPDIR/priv"
    mkdir -p "$PRIV"; touch "$PRIV/gh-token-repo"
    printf 'repo\towner/repo\t\n' > "$MANIFEST"
    qs_run 'PATH="$STUBS:$PATH"; SANDBOX_NAME=demo
            QS_CLONES_MANIFEST="$MANIFEST" QS_PRIVATE_DIR="$PRIV"
            QS_REPOS_DIR=/nonexistent/repos
            cleanup_clone_artifacts'
    [ "$status" -eq 0 ]
    [[ "$output" == *"can't be revoked via API"* ]]
}
