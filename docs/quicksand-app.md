# Quicksand.app: a status-bar app that runs the host brokers

Status (2026-11-25): steps 1–3 are built: the brokers write an event log,
`app/` holds Quicksand.app, and a sandbox moves to the app's sockets on its
next build. The app also ships the `qs` command (see "The qs command").
Step 4 (approvals) is next.

## Goal

A small native macOS app, living in the status bar, that:

1. shows which sandboxes exist and which are active;
2. **runs the host-side brokers** (Docker, credential refresh, speech) for every
   sandbox, the way Docker Desktop runs the Docker engine;
3. shows which sandbox asked a broker for what, live, with simple stats;
4. later, asks the user to approve sensitive requests.

## Before the app

Every sandbox got one LaunchAgent per broker (`com.quicksand.{docker,auth,say}-broker.NAME`).
Each one owns a Unix socket in that sandbox's `_quicksand/` and, for every
connection, launchd starts a fresh bash broker (`config/qs-*-broker`) with the
connection on stdin/stdout.

The broker learns **which sandbox is calling** from its own arguments: the
sandbox name is written into the LaunchAgent at install time. A client never
gets to name a sandbox, so one sandbox can't act on another's workspace,
containers or credentials. That is the reason for one socket per sandbox: bash
has no way to ask a socket who is on the other end.

The cost: about three LaunchAgents per sandbox, nowhere to see activity across
sandboxes, and logs that are free text (the Docker broker logs only
"connection").

## Design

```
sandbox ──▶ /Users/Shared/quicksand/docker.sock ──▶ Quicksand.app (listens on all broker sockets)
                                                     │ 1. accept
                                                     │ 2. getpeereid(fd) → uid → "qs-trading" → "trading"
                                                     │ 3. host-side policy: a quicksand sandbox? broker enabled for it?
                                                     │ 4. spawn: bash qs-docker-broker trading /Users/Shared/qs-trading …
                                                     │    with the connection as stdin/stdout
                                                     ▼
                                       bash broker (unchanged policy code) ──▶ streams to the sandbox
                                                     │
                                                     └──▶ appends one line to ~/.config/quicksand/events.jsonl
```

### One socket per broker type, identity from the kernel

- Three sockets total (`docker.sock`, `auth.sock`, `say.sock`) in
  `/Users/Shared/quicksand/`, a directory the app creates owned by the host
  user and writable by no one else (it refuses to start otherwise, and never
  removes a file at a socket path that isn't its own socket).
- **The sandbox profile needs one change.** `config/sandbox.sb` denies reads
  under `/Users` except the sandbox's own home and workspace, so step 3 adds
  `(allow file-read* (subpath "/Users/Shared/quicksand"))`. Connecting needs
  no write rule: a sandboxed process can connect to sockets outside its
  write-allowed paths (checked against `/var/run/mDNSResponder`).
- Anyone on the Mac can connect. The app rejects any peer whose uid isn't a
  quicksand sandbox user.
- **Identity:** `getpeereid()` on the accepted socket gives the caller's uid;
  `getpwuid()` maps it to `qs-NAME`. Both come from the kernel and the system
  user directory, which only an admin can change.
- **Policy = the broker specs qs renders.** For each connection the app loads
  `~/.config/quicksand/brokers/com.quicksand.<kind>-broker.<NAME>.plist` (the
  LaunchAgent plist minus launchd's socket keys, kept out of
  `~/Library/LaunchAgents` so launchd never loads it) and runs its
  `ProgramArguments` with its `EnvironmentVariables`, exactly as launchd did.
  For a sandbox not rebuilt since, it falls back to the old LaunchAgent plist
  in `~/Library/LaunchAgents`. No plist means that broker isn't enabled for the sandbox (so
  `qs docker NAME` / `qs docker NAME off` keep working unchanged). The plist
  and the broker script it names must be regular files owned by the host user
  and writable by no one else, its `Label` must match, and its arguments must
  name this sandbox. Nothing is read from the workspace, the sandbox's home, or
  the request.

### The app spawns; the bash brokers decide

(Speech no longer works this way: since the brokers started moving into the
app, it runs inside it — see "Brokers inside the app" below. Docker and
credentials still do.)

- The app **never reads or parses** what a sandbox sends. It accepts the
  connection, works out the caller, and hands the file descriptor to a fresh
  bash broker process, exactly as launchd does today. The broker gets the same
  arguments it gets from its LaunchAgent now.
- All request policy stays in the existing, tested bash: flag-free Docker
  command composition, symlink-resolved workspace checks, `_quicksand/`
  masking, label scoping, build-tag namespacing, the auth refresh lock, output
  sanitizing.
- One process per request is kept: a broker that crashes or hangs affects one
  request, not the app or other sandboxes. Brokers are started with
  `posix_spawn` and `POSIX_SPAWN_CLOEXEC_DEFAULT`, so they inherit only the
  connection (fd 0 and 1) and `/dev/null` (fd 2), with default signal handling
  and the environment launchd would give them.
- A sandbox can have at most 16 broker processes running at once; more
  connections are turned away with a message in that broker's protocol.

### When the app isn't running

Like Docker Desktop: brokers are unavailable. The sandbox clients (`qs-docker`,
`qs-auth-refresh`, `qs-say`) must say so plainly, e.g. "Quicksand app isn't
running on the host". The app is a login item that relaunches after a crash.
Broker processes already running finish their requests if the app dies.

### What the app shows

- Notifications (setting: every request / problems / off, default every
  request): "trading → Docker" when a connection arrives, "Refused uid 501
  (not a sandbox) → Docker" for a refusal, "trading → Docker failed" for a
  non-zero exit. They name the caller and the broker only: the app doesn't
  read requests, so the verb and target are in the event log, not the banner.

- Status-bar icon with a badge: active sandboxes, requests in the last hour;
  red when a broker is failing (refresh timeouts, Docker engine down).
- Menu: each sandbox, active or idle (processes per `qs-*` user), session
  count, Docker on/off, GCP token age, 1Password token staged or not.
- Feed window: live events, filterable by sandbox and broker.

Request details (verb, image, result) come from the event log the brokers
write through `qs-event`, since the app doesn't parse requests itself. Connection timing
and exit status the app sees directly.

### Approvals (later)

The app passes each broker an extra channel back to itself. A broker that is
about to do something sensitive (`run` of an image not seen before, a
credential refresh) asks; the app shows a notification with Allow / Deny. With
no answer within a deadline, the broker applies a configured default.

## Event log format (step 1)

`~/.config/quicksand/events.jsonl` (override: `QS_EVENTS_LOG`), one JSON object
per line, appended when a request ends. The brokers don't write it
themselves: each calls `qs-event` (`app/Sources/qs-event`, one Swift command
for all three), which Quicksand.app ships next to its own binary and passes
to every broker as `QS_EVENT_BIN`. A broker run without it (by hand, or by a
pre-app LaunchAgent) works but logs nothing. `qs-event` locks the log, so
concurrent brokers never interleave lines or rotate twice, and rotates it to
`events.jsonl.1` past about 5 MB (`QS_EVENTS_MAX_BYTES`).

```bash
qs-event --log FILE --broker docker|auth|say --sandbox NAME [--since EPOCH] -- VERB RESULT [FIELD VALUE]...
```

```json
{"ts":"2026-11-20T09:14:03Z","sandbox":"trading","broker":"docker","verb":"run","result":"ok","secs":12,"exit":0,"target":"node:20"}
{"ts":"2026-11-20T09:15:40Z","sandbox":"trading","broker":"docker","verb":"run","result":"rejected","secs":0,"exit":125,"target":"--privileged","reason":"run: bad image ref"}
{"ts":"2026-11-20T09:20:00Z","sandbox":"agent","broker":"auth","verb":"refresh","result":"error","secs":31,"providers":"gcp=ok,op=timeout"}
{"ts":"2026-11-20T09:21:07Z","sandbox":"agent","broker":"say","verb":"say","result":"ok","secs":2,"target":"agent is waiting for your input"}
```

| Field | Meaning |
|---|---|
| `ts` | UTC time the request ended |
| `sandbox`, `broker` | who asked, and which broker answered (`docker`, `auth`, `say`) |
| `verb` | `run`, `build`, `pull`, `ps`, `logs`, `stop`; `refresh`; `say`; or what an invalid request claimed |
| `result` | `ok`, `error` (the work failed or the host is misconfigured), `rejected` (policy said no), `shared` (auth: reused a refresh already in flight) |
| `secs` | whole seconds the request took (host bash is 3.2: no sub-second clock) |
| `exit` | Docker's exit code, when there was one |
| `target` | image, tag, container id or spoken text, as the client sent it (escaped) |
| `reason` | why it was rejected or failed |
| `providers` | auth: each provider's outcome, `name=ok`, `name=exit N`, `name=timeout` or `name=error` (could not be started), comma-separated |

Never logged: Docker `cmd` arguments, environment variables (names or values),
credential values, provider output.

Every value a sandbox sent is untrusted: `qs-event` drops control characters
and invalid UTF-8 and JSON-escapes the rest, so each line is valid JSON
whatever the client sent. Field names must be lowercase words and can't
override the fixed ones (`sandbox`, `broker`, …). Readers must still treat the content as
data.

The per-sandbox free-text logs (`*-broker-NAME.log`) stay as they are.

## Steps

1. **Event log in the three bash brokers.** Useful on its own (`jq` over one
   file instead of three logs per sandbox). Bats-tested.
2. **Quicksand.app v1** (done; see "The app today" below).
3. **Migration** (done): the sandbox profile allows reading
   `/Users/Shared/quicksand`; the sandbox clients (`qs-docker`,
   `qs-auth-refresh`, `qs-say`) default to the shared sockets and say
   "Quicksand.app isn't running on the host" when there is no socket (and
   `qs-docker` says "no answer" when a stale one doesn't answer). `qs` renders
   specs to `~/.config/quicksand/brokers/` and loads nothing into launchd; each
   build unloads and deletes that sandbox's old LaunchAgents and their
   `_quicksand/*.sock`. Sandboxes migrate one by one as they are rebuilt; the
   menu lists those still on LaunchAgents.
4. **Approvals.**

## The app

`app/` is a SwiftPM package (no Xcode project), macOS 14+:

- `QuicksandCore`: caller identity (`getpeereid` → `getpwuid_r` → `qs-NAME`,
  round-tripped), broker specs from the plists, spawning, the per-socket
  listener, sandbox status (processes per user via `proc_listpids`, live
  session records, staged tokens), the event-log reader (follows appends and
  rotation, skips bad lines) and stats.
- `Quicksand`: the status-bar app. The icon shows active sandboxes and turns
  into a warning sign when the brokers can't start or requests failed in the
  last hour. The panel has stat tiles, every sandbox with its state, the
  latest requests, a "Run brokers" switch (on by default) and "Open at login".
  The Activity window lists every request from the event log and every
  connection the app served, with filters.

```bash
swift test --package-path app                      # incl. the real docker broker end to end
app/scripts/bundle.sh                               # → app/build/Quicksand.app (ad-hoc signed)
app/scripts/install.sh                              # build + install to ~/Applications + link qs + open
```

Inside a quicksand sandbox, add `--disable-sandbox` to `swift build`/`swift
test`/`bundle.sh`: SwiftPM's own sandbox can't nest inside sandbox-exec. The
app's UI can only run on the host (sandbox users have no GUI session).

Sandboxes not rebuilt since step 3 still use their LaunchAgents: the app
lists them, flagged, but doesn't serve their requests.

## Brokers inside the app

The bash brokers are moving into the app one by one: speech first, then
credentials, then Docker, which also retires `qs-event`, `jq` and the last
plist templates. A broker inside the app implements `InProcessBroker`: the
listener still identifies the caller by uid and applies the 16-per-sandbox
cap, then asks the broker whether that sandbox may use it and hands it the
connection on a thread of its own (`BrokerClient`: bounded line reads,
writes, close). It writes its event-log line itself with `EventWriter`. In
the Activity window these requests show as "running in the app"; they have
no pid.

**Speech** (`SayBroker`): every built sandbox (one with
`~/.config/quicksand/install-NAME`, which every build writes) may speak. It
reads one line (at most 4096 bytes, within 10 s) and closes the connection
before speaking, drops control bytes, caps the text at 300 bytes without
splitting a character, and hands it to the app's `Speaker`: one
`AVSpeechSynthesizer` for the whole app (`SystemSpeaker`), driven from the
main thread, which queues messages from all sandboxes so they never
overlap. A request waits up to 90 s for its message (including those queued
before it) and is logged as an error if it wasn't spoken by then. Tests use
a fake speaker; the real voice can only be heard on the host. Builds no longer stage a speech broker or render a speech spec,
and the next build of each sandbox removes what earlier builds left
(`say-broker-NAME.sh`, its spec and log, or a pre-app LaunchAgent).

Host-side state for the next brokers (whether Docker is on for a sandbox,
the host's `docker` path, the PATH and `libexec/` the credential providers
need) is still to be decided between small files and a SQLite `state.db`
written through the Swift `qs`.

## The qs command

`qs` is moving from bash to Swift one command at a time, so there is always
one working `qs`. Step 1 (done): the Swift `qs` (`app/Sources/qs`) finds the
bash script and replaces itself with `/bin/bash qs.bash ARGS...` (`execv`,
so the terminal, sudo prompts, Ctrl-C, interactive sessions and the exit code
are the script's; arguments pass through as raw bytes). It looks for
`qs.bash` in this order (`LegacyCLI.locateScript`):

1. `$QS_BASH`, when set (tests, development);
2. `Contents/Resources/quicksand/qs.bash` inside the app, where `bundle.sh`
   copies it with `profile.d/`, `logout.d/`, `config/` and `libexec/`;
3. the nearest directory above the executable holding `qs.bash` and
   `profile.d/` — a checkout, for `app/.build/debug/qs`.

`app/scripts/install.sh` builds the app, installs it to `~/Applications` and
links `/usr/local/bin/qs` to its qs (`--dev`: to the debug build). The menu's
"Install qs command" makes the same link through an admin prompt. Both
replace only a missing link or one to another qs, never anything else.

Step 2 (done): Swift parses every command line (`QsCLI.parse`, mirroring
`parse_args` field for field, including `QUICKSAND_ARGS`, which it splits
with the same zsh call) and refuses bad ones with qs.bash's own messages. It
answers `--help`, `--version` and `list` itself (`SandboxList`, sorted by the
locale's collation as bash sorts a glob) and hands everything else to
`qs.bash` with the original arguments. qs.bash no longer has `--help`,
`--version` or `list`: run directly, it refuses them and points at `qs`.
It keeps `parse_args`, because the commands still in bash need the values it
sets; a Swift test runs it on a table of command lines and requires the same
result as `QsCLI.parse`, and bats compares the error messages end to end.

Next: commands move over one by one (`docker`, the credential commands,
`clone`/`memory`/`ssh-auth`, `uninstall`, `build`, `shell`/`claude`), and
finally `qs.bash` goes away.

## Open questions

- Signing: "Open at login" uses `SMAppService.mainApp` on an ad-hoc-signed
  app. Untested on the host; if macOS refuses, add it by hand in System
  Settings → General → Login Items.
- The app bundle contains code that decides who a caller is, so it must live
  where sandboxes can't write (`/Applications` or `~/Applications` of the host
  user both qualify).
- What the sandbox-side clients print when the app is off, and whether
  `qs-auth-refresh` at SSH login should wait briefly for it.

## Out of scope

The sandboxes' claude.ai login (Claude in Chrome relay, claude.ai connectors)
doesn't pass through any quicksand broker, so this app can neither see nor stop
it. That needs a separate fix (a dedicated account for sandboxes, or root-owned
managed settings).
