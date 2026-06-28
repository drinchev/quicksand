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
  and Commit statuses (read). It cannot push code, change repo settings, or
  reach any other repository.
- git push/pull use a repo-scoped SSH deploy key, NOT the token. Normal git
  over SSH works; the token alone cannot write repository contents.

## Credentials
- Scoped credentials live as files under /Users/Shared/qs-*/_quicksand/
  (the gh token and, if configured, a short-lived GCP token).
- Network access is unrestricted.
