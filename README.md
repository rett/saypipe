# saypipe

Launch remote Wayland apps through [waypipe](https://gitlab.freedesktop.org/mstoeckl/waypipe)
over ssh, with per-host options for GPU buffers, audio forwarding and ssh
connection sharing.

```
saypipe myvm foot                 # run foot on myvm, shown here
saypipe --host-add myvm           # enable myvm (checks it has waypipe)
saypipe --probe --apply myvm      # test what it supports and turn that on
saypipe --link-add myvm           # now `myvm foot` works too
```

Everything after the host is the command to run there. Launches run
detached, so closing the terminal doesn't close the app. A launch that fails
right away (ssh error, command not found) is reported in the terminal; all
such failures are also appended to `~/.local/state/saypipe/errors.log`.

## Install

saypipe needs bash (4.4 or newer), an OpenSSH client and waypipe locally,
and waypipe on each remote host. It otherwise uses only POSIX tools, so it
runs on Linux distributions and the BSDs.

```
./install.sh                         # system-wide: packages + /usr/local/bin/saypipe
./install.sh --user                  # per-user: packages + ~/.local/bin/saypipe,
                                     #   a link to this checkout
./install.sh [--user] --uninstall    # remove it, its completions and your host links
./install.sh [--user] --uninstall --purge
                                     # ... and your saypipe config and state
```

`install.sh` is POSIX `sh` (it runs before bash exists) and installs only
what's missing from your PATH, using apt, dnf, yum, zypper, pacman, apk, xbps,
emerge or FreeBSD `pkg` through sudo or doas. Uninstalling keeps packages.
`PREFIX` changes `/usr/local`; `SAYPIPE_BIN_DIR` changes `~/.local/bin`.

### Shell completion

`install.sh` also installs completions for bash (with bash-completion), zsh
and fish. They complete options, hosts (enabled hosts and aliases first, then
the `Host` names in your ssh config, following `Include`) and, after options
like `--gpu-remove` or `--alias-remove`, only what applies there.
`saypipe --completion-hosts enabled` limits host completion to enabled hosts.

System-wide installs use `/usr/local/share` (fish falls back to
`/etc/fish/completions` where it doesn't search there); `--user` installs link
them into your own completion directories. For zsh with `--user`, add
`fpath=(~/.local/share/zsh/site-functions $fpath)` to `~/.zshrc` before
`compinit` if completion doesn't load.

### Newer waypipe (optional)

saypipe works with your distribution's waypipe. If that one is too old (common
on LTS releases), `scripts/build-waypipe.sh` builds the latest waypipe release
with all features on apt-based systems and installs it to `/usr/local`. It
also builds a private ffmpeg in `/opt/ffmpeg-waypipe` if the system's is too
old for waypipe's video support. Rerun it to update. It needs sudo and takes
a while.

The source-build helper now reuses only recognized, clean upstream checkouts.
It refuses dirty or unfamiliar source trees and uses separate `waypipe-build`
and `ffmpeg-build` directories carrying ownership markers. It stages private
FFmpeg as the invoking user before replacing a verified owned prefix, and
retains the previous prefix through verification for rollback.

Existing private FFmpeg installations from older helper versions lack the new
ownership header in `.build-info` and are deliberately refused. Back up and
inspect that installation before moving it aside or selecting a new private
`FFMPEG_PREFIX`. Do not add the ownership header to an unfamiliar directory.
An interrupted build may leave a `.saypipe-lock`, `.new.*` or `.old.*` sibling
that needs inspection. Linker registration remains system-wide, and waypipe's
own installation is outside the FFmpeg rollback transaction.

## Troubleshooting

```
saypipe --version                   # identify the installed copy
saypipe --doctor                    # local tools, display and config health
saypipe --probe myvm                 # remote capabilities and portal availability
saypipe --foreground myvm foot       # stream output and wait for the app
```

`--verbose` is an alias for `--foreground`. Both precede the host. Host links
can use `SAYPIPE_FOREGROUND=1 myvm foot`. Detached launches remain the default.
The launcher confirms its worker started before reporting success.

`--doctor` is local and read-only. `--probe` authenticates over SSH and reports
the remote shell, D-Bus session helper and portal files without activating
portal services. Availability does not prove that a file dialog will open.
Post-authentication probe commands have a 15-second limit, configurable with
`SAYPIPE_PROBE_TIMEOUT`. SSH's authentication step can still prompt normally.

Session output is kept in a private temporary directory, capped at 64 KiB
(configurable with `SAYPIPE_LOG_BYTES`, between 4 KiB and 1 MiB). Unexpected
exits are recorded in the private `errors.log`, which retains a bounded tail.
An exit of 1 during the first five seconds, or with a recognizable error
message, counts as a failure. A quiet exit of 1 after that window may be a
normal GUI close and is omitted. `SAYPIPE_STARTUP_WINDOW` changes that window.
The original exit status is preserved in foreground mode.

Configuration updates are serialized and replaced atomically beside their
resolved targets. Intentional symlinks and existing permissions are preserved.
A writable target in a directory that forbids replacement is updated in place
under the lock. Deliberately read-only files are refused. An interrupted writer's
lock is recovered only when its recorded owner on this host is dead. A lock
with an unknown or remote owner times out and is reported for inspection.

When `user@host` inherits settings from `host`, removals require the exact
saved entry. Saypipe reports the inherited entry instead of silently removing
shared host settings. An exact default for `user@host` takes precedence over
an inherited `host` default.

## Enabled hosts

saypipe keeps a list of enabled hosts, the hosts it works with. A host is
enabled once saypipe has confirmed over ssh that it has waypipe:

```
saypipe --host-add myvm              # checks for waypipe, then enables it
saypipe --host-add --force myvm      # enable without the check (e.g. host offline)
saypipe --list                       # enabled hosts with their options
saypipe --host-remove myvm           # remove it with all its options, aliases and link
```

Options belong to enabled hosts: adding one to a host that isn't enabled yet
enables it first, with the same check (`--force` works there too). Launching
doesn't need an enabled host: `saypipe <host> <command>` works for any host
ssh can reach.

### File dialogs and D-Bus

Every launch automatically uses a private D-Bus session when the remote host
has `dbus-run-session`. Install it on the remote host for applications that
use desktop portals, such as Electron file dialogs. The host also needs a
file chooser portal backend, such as `xdg-desktop-portal-gtk`, and
`xdg-desktop-portal`.

Portal services then inherit the Wayland display created for that launch, so
file dialogs open through the same waypipe connection. Concurrent launches
get separate buses and displays. The bus ends when the command exits.

A running single-instance app may reuse an older process and its bus. Fully quit
that app before relaunching it to adopt the new session.

The private bus also isolates the app from the host's shared session services,
including existing D-Bus app instances and session keyrings. File dialogs
browse files on the remote host. Hosts without `dbus-run-session` use their
existing session bus and may still need portal environment configuration.

### GPU buffers

| Host | waypipe options | Why |
|---|---|---|
| default | `-n -c zstd` | `-n` (`--no-gpu`) sends shared-memory buffers. Hosts without a GPU need it. |
| `saypipe --gpu-add <host>` | `-c zstd` | Lets apps share GPU buffers (dmabufs). |

`-c zstd` uses about 30% less bandwidth than waypipe's default lz4 at the same
frame rate. `SAYPIPE_OPTS="..."` replaces the options for every host.

### Audio

waypipe doesn't carry audio. For hosts with `saypipe --audio-add <host>`,
saypipe forwards the local PulseAudio socket over the same ssh connection and
starts the app with `PULSE_SERVER` pointing at it, so its sound plays here:

```
waypipe ... ssh -R /tmp/saypipe-pulse-<random>.sock:$XDG_RUNTIME_DIR/pulse/native <host> \
    env PULSE_SERVER=unix:/tmp/saypipe-pulse-<random>.sock <command...>
```

- Encrypted with the ssh session and needs no open ports.
- Each session gets its own random socket name, and saypipe removes it on the
  remote host afterwards (sshd leaves forwarded sockets behind; with a shared
  connection it also cancels the forward there).
- If there's no local PulseAudio socket, the app starts without audio.
- Needs a PulseAudio server locally (PipeWire's `pipewire-pulse` counts) and,
  on the remote host, apps that use libpulse (most do) and sshd with
  `AllowStreamLocalForwarding` (the default). Apps talking to PipeWire or ALSA
  directly still play on the remote host.

### Connection sharing

Every launch opens an ssh session, and audio launches a second, short one for
cleanup. On hosts whose firewall rate-limits ssh (e.g. `ufw limit`, 6 new
connections per 30 s) quick launches can get refused. For hosts with
`saypipe --share-add <host>`, saypipe runs ssh with:

```
-o ControlMaster=auto -o ControlPath=$XDG_RUNTIME_DIR/saypipe/cm/%C
-o ControlPersist=10m -o ServerAliveInterval=15 -o ServerAliveCountMax=3
```

so all sessions to the host reuse one connection and start faster. The master
stays for `SAYPIPE_SHARE_PERSIST` (default `10m`) after the last session, and
the keepalives notice a dropped connection within about 45 s. The trade-off:
a dropped connection closes every app on that host at once.
`saypipe --share-exit <host>` closes a stuck master (and its apps). Hosts
without the option use whatever your ssh config says.

### Default commands

A host can have a command that runs when none is given, and a global default
covers hosts without their own:

```
saypipe --default-set myvm ghostty -e htop   # `saypipe myvm` runs it
saypipe --default-set --global ghostty       # for every other host
saypipe --default-remove myvm
saypipe --default-remove --global
saypipe --list defaults
```

An explicit command always wins. Options go before the host; everything after
it is the command, stored as typed.

### Links and aliases

`saypipe --link-add myvm` creates a `myvm` command in `~/.local/bin` (or
`$SAYPIPE_BIN_DIR`), so `myvm foot` works like `saypipe myvm foot`. saypipe
won't create a link that shadows an existing command; give such a host an
alias instead:

```
saypipe --alias-add vm-dev dev       # `vm-dev foot` connects to host "dev"
saypipe vm-dev foot                  # aliases work on the command line too
saypipe --alias-remove vm-dev        # remove the alias and its link
```

Options and defaults belong to the real host, and the management options
accept an alias in its place. An alias can't take the name of an enabled host,
and `--host-remove` refuses alias names.

### Probing a host

`saypipe --probe <host>...` tests what a host supports and shows what's
enabled:

```
$ saypipe --probe myvm
myvm
  ssh      ok      connected
  waypipe  ok      waypipe 0.11.2 (dmabuf: yes)
  shared   yes     extra sessions reuse one connection
  gpu      yes     Virtio-GPU Venus (Quadro RTX 4000) on /dev/dri/renderD128
  audio    yes     reached local sound server: PulseAudio (on PipeWire 1.6.0)
  host     enabled
  options  shared
  -> saypipe --gpu-add myvm
  -> saypipe --audio-add myvm
```

- **shared:** the probe runs over one temporary shared connection; extra
  sessions over it must work. It opens a single TCP connection, so it won't
  trip ssh rate limits.
- **gpu:** waypipe built with dmabuf, an accessible `/dev/dri/renderD*` and a
  hardware Vulkan device (software Vulkan doesn't count). Without `vulkaninfo`
  on the host the result is `likely`.
- **audio:** forwards your PulseAudio socket for real and asks the sound
  server for its name through it.

`--apply` enables the host (if it has waypipe) and every supported option
that's off. Options that are on but unsupported get a warning with the command
to turn them off; `--apply` doesn't remove anything.

## Reference

In short (`saypipe --help` has the details):

```
saypipe [--] <host> [<command...>]   run a command on a host
<host-link> [<command...>]           the same, through a link

Hosts:
  --host-add [--force] <host>...     enable hosts after checking for waypipe
  --host-remove <host>...            remove hosts with their options, aliases, links
  --list [<list>]                    enabled hosts with their options, or one list:
                                     hosts gpu audio share aliases links defaults
  --probe [--apply] <host>...        test what hosts support; --apply enables it

Host options (adding one enables the host; --force works here too):
  --gpu-add / --gpu-remove <host>...
  --audio-add / --audio-remove <host>...
  --share-add / --share-remove <host>...
  --share-exit <host>...             close a shared connection (closes its apps)
  --default-set <host>|--global <command...>
  --default-remove <host>...|--global
  --alias-add <alias> <host>, --alias-remove <alias>...
  --link-add / --link-remove <host>...

Settings:
  --completion-hosts [all|enabled]
  --foreground, --verbose           stream output and wait for the app
  --doctor                          local tools, display and config health
  --version                         installed version
  -h, --help
```

Management commands report per host, print errors as `saypipe: ...` on
stderr, and exit 1 when something couldn't be done (2 for wrong arguments).

Environment: `SAYPIPE_OPTS` (waypipe options for every host),
`SAYPIPE_BIN_DIR` (links), `SAYPIPE_SHARE_PERSIST` (shared connection
lifetime, default `10m`), `SAYPIPE_WAIT` (seconds to watch a launch for
failure, default `2`), `SAYPIPE_FOREGROUND`, `SAYPIPE_STARTUP_WINDOW`,
`SAYPIPE_LOG_BYTES` and `SAYPIPE_PROBE_TIMEOUT` (see Troubleshooting).

## Files

- `~/.config/saypipe/hosts`: enabled hosts, one per line (hosts with options
  count as enabled too).
- `~/.config/saypipe/gpu-hosts`, `audio-hosts`, `share-hosts`: options, one
  host per line, `#` comments.
- `~/.config/saypipe/aliases`: `<alias> <host>` per line.
- `~/.config/saypipe/commands`: `<host> <command...>` per line (`*` is the
  global default).
- `~/.config/saypipe/settings`: `<key> <value>` per line (`completion-hosts`).
- `$XDG_RUNTIME_DIR/saypipe/cm/`: control sockets of shared connections.
- `~/.local/state/saypipe/errors.log`: failed launches.

## License

MIT. See [LICENSE](LICENSE).
