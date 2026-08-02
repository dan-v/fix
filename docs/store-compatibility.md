# Nix/Lix store compatibility

`fix` speaks the stable Nix worker protocol itself; it never discovers or
executes an installed Nix or Lix. Unsupported selectors and settings fail with
a specific error instead of falling back to whatever is on `PATH`.

## Selectors

| Store selector | Status |
|---|---|
| `daemon` | supported (default Unix socket) |
| `unix://PATH`, `?protocol=legacy-combined` | supported |
| `unix://DIR?protocol=legacy`, `?protocol=any` | supported (`DIR/socket`) |
| `tcp://HOST:PORT` | supported |
| `ssh-ng://HOST` | supported (`port`, `ssh-key`, `compress`) |
| `unix://DIR?protocol=lix-xp-1` | not implemented |
| `local`, `auto`, chroot roots | not implemented |

Select a store with `--store`, `NIX_REMOTE`, or the `nix.conf` `store`
setting. The daemon must speak worker protocol 1.26+ (Nix ≥ 2.4); CI
exercises both CppNix and Lix daemons. The default socket, GC-root checks,
and system-profile updates follow `NIX_STATE_DIR`; `NIX_DAEMON_SOCKET_PATH`
overrides the socket. As with Nix, only user config, `$NIX_CONFIG`, and CLI
overrides are forwarded to the daemon — system `nix.conf` stays daemon-side
policy. `ssh-ng://` starts the remote `nix-daemon --stdio` in SSH batch mode,
so hosts that require an interactive prompt fail rather than hang.

## Not implemented

- `lix-xp-1` is Lix's experimental Cap'n Proto RPC protocol with no stability
  guarantee — a different protocol, not another framing of the worker
  protocol. Use `protocol=any` for Lix; it reaches the stable worker socket
  on any release. ([selectors][lix-stores], [schema][lix-capnp])
- `local`, `auto`, and chroot roots need a native local-store backend
  (filesystem layout, locking, GC roots, build orchestration), which does not
  exist yet.

[lix-stores]: https://docs.lix.systems/manual/lix/nightly/command-ref/new-cli/nix3-help-stores.html
[lix-capnp]: https://git.lix.systems/lix-project/lix/src/branch/main/lix/libstore/daemon.capnp
