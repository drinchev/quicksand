# Changelog

## 0.2.0 — 2026-08-03

The provider refactoring series. The CLI is unchanged throughout.

- **Auth providers**: the GCP, GitHub and 1Password integrations moved out
  of `qs` into standalone scripts behind one contract
  (`libexec/qs-auth-{gcp,gh,op}`: `provision` / `refresh` / `cleanup`,
  plus `mint` for GCP). `qs` shrank from 1,655 to ~1,440 lines while
  gaining features; launch and uninstall touch credentials only through
  the generic provider loops. See "Architecture" in the README. (#23,
  #24, #25)
- **Docker via a host-side broker** (`qs docker`): sandboxes run
  containers on the host engine through a policy broker — workspace-only
  mounts, capabilities dropped, resource caps, per-sandbox labels and a
  forced image-tag namespace; no Docker socket ever visible. (#19)
- **Broker hardening**: `_quicksand/` (live credentials, the broker's own
  socket) is masked out of containers by an empty anonymous volume; the
  workspace root and `_quicksand` are rejected as build contexts; the
  trust boundary is documented — enabling `qs docker` adds the container
  engine to the sandbox's TCB. (#27)
- **Fix**: the provider dispatch failed in real runs — bash rejects
  env-prefix assignment (`VAR=x cmd`) for readonly names, so providers
  silently never ran; the child environment is now built with `env`,
  locked by a readonly-mirroring regression test. (#26)
- **Session assembly under test**: `build_session_command` extracted from
  `cmd_launch` as a pure function; a new end-to-end test executes an
  assembled command in real zsh (hooks, cd-with-spaces, argv round-trip,
  exit trap). (#28)
- **profile.d shared lib**: `00-lib.sh` (sourced by hooks, deliberately
  not executable so the session loop skips it) dedupes `find_pnpm`,
  `ensure_collection` and the arch mapping across eight hooks. (#29)
- Tests: 71 → 120; CI lints `libexec/` and the docker broker scripts.

## 0.1.0

Initial release: per-repo macOS user-account sandboxes (`dscl` + group
ACLs + `sandbox-exec`), `qs clone` with per-repo deploy keys, GitHub /
GCP / 1Password auth, shared agent memory (`notes/` + qmd, `qs memory`),
content-fingerprinted automatic rebuilds.
