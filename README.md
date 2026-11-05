# saypipe

Launch remote Wayland apps through [waypipe](https://gitlab.freedesktop.org/mstoeckl/waypipe)
over ssh, with per-host defaults for GPU buffers, audio forwarding and ssh
connection sharing.

```
saypipe <host> <command...>       # e.g. saypipe myvm foot
<host> <command...>               # via a host link: saypipe --link myvm; myvm foot
```

Each launch runs detached, so closing the terminal doesn't close the app.
Failures that mean something (ssh error, command not found) are appended to
`~/.local/state/saypipe/errors.log` with the tail of waypipe's output.

## Install

saypipe needs bash (3.2 or newer), an OpenSSH client and waypipe locally,
and waypipe on each remote host. It otherwise uses only POSIX tools, so it
runs on Linux distributions and the BSDs.

```
./install.sh                         # system-wide: packages + /usr/local/bin/saypipe
./install.sh --user                  # per-user: packages + ~/.local/bin/saypipe,
                                     #   a link to this checkout
./install.sh [--user] --uninstall    # remove it and your host links to it
./install.sh [--user] --uninstall --purge
                                     # ... and your saypipe config and state
```

`install.sh` is POSIX `sh` (it runs before bash exists) and installs only
what's missing from your PATH, using apt, dnf, yum, zypper, pacman, apk, xbps,
emerge or FreeBSD `pkg` through sudo or doas. Uninstalling keeps packages.
`PREFIX` changes `/usr/local`; `SAYPIPE_BIN_DIR` changes `~/.local/bin`.

## Per-host waypipe options

| Host | Options | Why |
|---|---|---|
| default | `-n -c zstd` | `-n` (`--no-gpu`) sends shared-memory buffers. Hosts without a GPU need it. |
| listed in `~/.config/saypipe/gpu-hosts` | `-c zstd` | Lets apps share GPU buffers (dmabufs). |

`-c zstd` uses about 30% less bandwidth than waypipe's default lz4 at the same
frame rate. `SAYPIPE_OPTS="..."` replaces the options for every host.

## Audio (opt-in)

waypipe doesn't carry audio. For hosts listed in `~/.config/saypipe/audio-hosts`,
saypipe forwards the local PulseAudio socket over the same ssh connection and
starts the app with `PULSE_SERVER` pointing at it, so its sound plays on this
machine:

```
waypipe ... ssh -R /tmp/saypipe-pulse-<random>.sock:$XDG_RUNTIME_DIR/pulse/native <host> \
    env PULSE_SERVER=unix:/tmp/saypipe-pulse-<random>.sock <command...>
```

- Encrypted with the ssh session and needs no open ports.
- Each session gets its own random socket name, and saypipe removes it on the
  remote host afterwards, since sshd leaves forwarded sockets behind.
- If there's no local PulseAudio socket, the app starts without audio.
- With ssh connection sharing (`ControlMaster`), the master keeps forwards
  open after their session ends, so saypipe also cancels its audio forward
  there (`ssh -O cancel`).
- Needs a PulseAudio server locally (PipeWire's `pipewire-pulse` counts) and,
  on the remote host, apps that use libpulse (most do) and sshd with
  `AllowStreamLocalForwarding` (the default). Apps talking to PipeWire or ALSA
  directly still play on the remote host.

## Connection sharing (opt-in)

Every launch opens an ssh session, and audio launches a second, short one for
cleanup. On hosts whose firewall rate-limits ssh (e.g. `ufw limit`, 6 new
connections per 30 s) quick launches can get refused. For hosts listed in
`~/.config/saypipe/share-hosts`, saypipe runs ssh with:

```
-o ControlMaster=auto -o ControlPath=$XDG_RUNTIME_DIR/saypipe/cm/%C
-o ControlPersist=10m -o ServerAliveInterval=15 -o ServerAliveCountMax=3
```

so all sessions to the host reuse one connection and start faster. The master
stays for `SAYPIPE_SHARE_PERSIST` (default `10m`) after the last session. The
keepalives notice a dropped connection within about 45 s.

Trade-off: a dropped connection closes every app on that host at once.
`saypipe --share-exit <host>` closes a stuck master (and its apps).

Hosts not listed use whatever your ssh config says, so sharing configured
there still works.

## Management

```
saypipe --link <host>...        create host links
saypipe --unlink <host>...      remove host links (only ones pointing to saypipe)
saypipe --gpu-add <host>...     host runs without -n
saypipe --gpu-remove <host>...  host goes back to -n
saypipe --gpu-list              list GPU-enabled hosts
saypipe --audio-add <host>...   host's app audio plays on this machine
saypipe --audio-remove <host>...
saypipe --audio-list            list audio-enabled hosts
saypipe --share-add <host>...   sessions to host share one ssh connection
saypipe --share-remove <host>...
saypipe --share-list            list hosts with connection sharing
saypipe --share-exit <host>...  close the shared connection (and its apps)
saypipe --list                  every known host, with GPU/audio/sharing notes
```

`--list` marks a shared host `shared (connected)` while its master is open.

Host links go in `$SAYPIPE_BIN_DIR` (default `~/.local/bin`). They point at
`saypipe` there when it's this script, so links stay relative.

## Files

- `~/.config/saypipe/gpu-hosts`: GPU opt-in, one host per line, `#` comments.
- `~/.config/saypipe/audio-hosts`: audio opt-in, same format.
- `~/.config/saypipe/share-hosts`: connection-sharing opt-in, same format.
- `$XDG_RUNTIME_DIR/saypipe/cm/`: control sockets of shared connections.
- `~/.local/state/saypipe/errors.log`: failed launches.

## License

MIT. See [LICENSE](LICENSE).
