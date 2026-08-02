# Nix/Lix store compatibility

`fix` implements the store protocol itself. At runtime it never discovers or
executes a locally installed `nix`, `lix`, `nix-daemon`, `nix-store`, `nix-env`,
or `nix-copy-closure`. A local daemon is a protocol peer, not a helper
executable. An explicit `ssh-ng://` selector asks SSH to start the remote host's
`nix-daemon --stdio` worker endpoint, which is the remote store itself.

## Compatibility matrix

| Store selector | Status | Transport |
|---|---|---|
| `daemon` | supported | stable worker protocol over the default Unix socket |
| `unix://PATH` | supported | stable worker protocol over `PATH` |
| `unix://PATH?protocol=legacy-combined` | supported | stable worker protocol over `PATH` |
| `unix://DIR?protocol=legacy` | supported | stable worker protocol over `DIR/socket` |
| `unix://DIR?protocol=any` | supported | stable worker protocol over `DIR/socket` |
| `tcp://HOST:PORT` | supported | stable worker protocol over TCP |
| `ssh-ng://HOST` | supported | stable worker protocol over SSH to the remote daemon; `port`, `ssh-key`, and `compress` query settings are supported |
| `unix://DIR?protocol=lix-xp-1` | not implemented | native Lix RPC client required |
| `local`, `auto`, absolute chroot roots | not implemented | native local-store backend required |

The stable worker client accepts protocol 1.26 through 1.35 and advertises
1.35. It is exercised in CI against both CppNix and Lix daemons. The default
socket, direct GC-root checks, and local system-profile updates follow
`NIX_STATE_DIR`; `NIX_DAEMON_SOCKET_PATH` remains an explicit socket override.

Unsupported selectors fail during CLI setup with a selector-specific message.
They do not fall back to a local implementation found on `PATH`.
Unsupported SSH settings, including `remote-program` and `remote-store`, also
fail explicitly instead of being ignored.

## Why XP is separate

Lix documents `lix-xp-1` as an experimental RPC protocol. Its current source
implements it with Cap'n Proto RPC, labels the schema as having no stability
guarantee, and negotiates a tunneled-legacy protocol identifier containing the
exact Lix package version. Supporting it responsibly therefore means owning a
Cap'n Proto RPC client and version adapters; it is not another worker-protocol
framing mode.

- [Lix store URL protocol selection](https://docs.lix.systems/manual/lix/nightly/command-ref/new-cli/nix3-help-stores.html)
- [Lix experimental daemon RPC schema](https://git.lix.systems/lix-project/lix/src/branch/main/lix/libstore/daemon.capnp)

Until that protocol stabilizes, `protocol=any` is the preferred Lix selector:
it reaches the stable worker socket without coupling `fix` to one Lix release.

## Native backend order

1. Keep the stable daemon backend as the compatibility baseline.
2. Introduce a separate local-store backend for `local` and chroot roots. It
   must own filesystem layout, validity metadata, locking, GC-root handling,
   and build orchestration; routing these selectors through a daemon adapter is
   not local-store support.
3. Implement remote `fix switch` closure copying through store operations. Do
   not restore the old local `nix-copy-closure` or remote `nix-env` calls.
4. Revisit `lix-xp-1` when its stability/versioning story can support an
   independent client, or deliberately add Cap'n Proto and versioned adapters.

These are separate backends. They should share the realization-facing store
operation interface, not transport conditionals inside the stable worker
client.
