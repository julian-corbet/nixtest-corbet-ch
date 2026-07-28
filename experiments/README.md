# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing
up properly. Nothing here is guaranteed to work, be maintained, or survive the
next cleanup pass. If something turns out to matter, distill the finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable.

This is also the open-questions ledger for this project's own judgment calls.

## 001 — a third consumer of `lib/broken-disk.nix`?

**Question:** so far this fixture has exactly the one consumer this
repo's own `checks/fixtures-boot-vm-test.nix` proves it against. A real
repair-tooling module's own test suite (the obvious second real consumer,
alongside whatever `nixrescue` eventually migrates its own inline
broken-disk block in `checks/rescue-vm-test.nix` to use) would be the
first genuine outside evidence that the shape chosen here (plain scripts,
a bare size, a bare kernel-module list — see `docs/design.md`) is actually
the right one, rather than merely the first one that occurred to whoever
wrote it.

**What would settle it:** a second real consumer appearing and needing
something this fixture's current shape does not already provide —
multiple containers on one disk, a different unlock mechanism than a
literal passphrase, or a marker-verification step richer than a single
grep. Until then, extending the option surface pre-emptively would be
exactly the kind of guessed generality this family's own design values
warn against.

## 002 — `lib/efi-disk.nix`'s `extraEspFiles` against a real pointer-file consumer

**Question:** `checks/esp-contents-test.nix` proves `extraEspFiles` places
arbitrary files at arbitrary ESP paths, byte-for-byte. It does not prove
that a *booted* system can actually read one back off the ESP at runtime
(`checks/fixtures-boot-vm-test.nix` never mounts the ESP from inside
Linux at all — real firmware reads it directly, which is the whole point
of that check, but it leaves the "an initrd script reads a pointer file
off this same ESP" path — `nixrescue`'s own actual use case — unexercised
here).

**Reasoning as it stands:** proving that specific path here would mean
reproducing `nixrescue`'s own slot-selection `postDeviceCommands` script
inside this repo, which is exactly the layer `docs/design.md` says stays
on the consumer's side of the boundary. The build-time byte-check is the
right amount of proof for a fixture that does not own that mechanism.

**What would settle it:** `nixrescue` itself migrating its own
`mkTestDisk` to call `lib.mkEfiDisk` instead of its current hand-rolled
copy — at which point `nixrescue`'s own, already-proven
`rescue-uefi-boot-vm-test.nix` becomes the real end-to-end evidence, and
this repo's own build-time check stays exactly what it is now: proof of
the part this repo actually owns.
