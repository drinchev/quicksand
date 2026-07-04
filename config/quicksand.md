# Environment: quicksand sandbox

You are running inside a quicksand sandbox — a dedicated, isolated macOS user
account, NOT the host developer's machine. Do not assume access to the host's
home directory, files, or credentials.

## Filesystem access
- Writable: ~ (this sandbox's home), /Users/Shared/qs-* (the workspace shared
  with the host), /tmp and per-user scratch space.
- Readable: system directories (/usr, /bin, /etc, /opt).
- No access: every other /Users/* home, /Volumes/*, and /Library/Keychains.

## GitHub access
- Use the `gh` CLI for all GitHub API work: opening and commenting on pull
  requests, reading commits and branches, and reading or re-running CI.
- `gh` is signed in (when `qs gh-auth` has been run) with a fine-grained token
  scoped to a SINGLE repository. Its permissions are: Pull requests (write),
  Contents (read), Actions (write — so it can re-run workflows), Checks (read),
  Commit statuses (read), and Variables (read — so `gh variable list` works).
  It cannot push code, change repo settings, or reach any other repository.
- git push/pull use a repo-scoped SSH deploy key, NOT the token. Normal git
  over SSH works; the token alone cannot write repository contents.

## Credentials
- Scoped credentials live as files under /Users/Shared/qs-*/_quicksand/
  (the gh token and, if configured, a short-lived GCP token).
- Network access is unrestricted.

## App secrets (1Password)
- If `qs op-auth` has been run, app secrets (API keys, passwords, etc.) live in
  a per-sandbox 1Password vault and the `op` CLI is authenticated via the
  OP_SERVICE_ACCOUNT_TOKEN environment variable. The vault is named after this
  sandbox's user account (`qs-<name>`, i.e. $USER) and is the only vault the
  service account can see. Fetch secrets on demand:
  `op read "op://$USER/<item>/<field>"` or
  `op run --env-file=<file> -- <command>`.
- Prefer fetching at the point of use — these secrets are deliberately NOT
  written to disk. Don't copy them into files or commit them.

### Checking whether op is authenticated

- "op auth is active" usually refers to the user's interactive/host session,
  not your (non-interactive) tool shell. Verify in YOUR shell first:
  `printenv OP_SERVICE_ACCOUNT_TOKEN >/dev/null && echo set || echo unset`,
  then `op vault list` — "No accounts configured" means not authenticated here.
- The token is loaded by a managed block in ~/.zshrc that reads
  $SHARED_WORKSPACE/_quicksand/op-token (a 0600 file). profile.d scripts are
  executed, not sourced, so a non-interactive shell may not have it — and if
  the op-token file is absent, `op` isn't available to you at all. In that
  case, hand the user a ready-to-run command instead of running it yourself.

### Secret handling when creating items

- Never print a secret value or write it to disk or git.
- Read it without echoing and clear it afterwards: `read -rs KEY` … `unset KEY`.
- CLI field args (e.g. `credential=$KEY`) are briefly visible in `ps` — fine
  for a personal vault, but worth mentioning to the user.

### Item conventions

- Use the built-in "API Credential" category; the secret goes in the
  `credential` field.
- Put the description in `notesPlain` (or a labeled `description[text]=…`
  field).
- The title must be a kebab-case slug (e.g. `anthropic-api-key`, not
  "Anthropic API Key") so the reference `op://$USER/<slug>/credential` is
  clean and predictable. If a downstream store has its own name for the
  secret, match the slug to it.

### Create / rename

```sh
read -rs KEY
op item create --category "API Credential" --title "anthropic-api-key" \
  --vault "$USER" "credential=$KEY" "notesPlain=<what it's for>"
unset KEY

op item edit "<old title>" --title "<slug>"   # rename an existing item
```
