# Design notes

## Why a fixture library, and why *this* shape

Two projects in this family — `nixboot` and `nixrescue` — need to boot a
disk they built themselves through real UEFI firmware in a
`pkgs.testers.nixosTest`. `nixrescue` built that harness first, to prove
its own cold-mode boot chain end to end (see its own
`checks/rescue-uefi-boot-vm-test.nix`). `nixboot` needs the identical
mechanism for its own `nixboot.extraEntries` pipeline — and `nixboot` is
the *lower* layer: a rescue sits in front of a main's own boot chain,
which is `nixboot`'s job, never `nixrescue`'s. `nixboot` depending on
`nixrescue` to borrow a test fixture would invert that arrow.

The family's own placement rule decides this without a judgment call: "if
two products would want it, it is a module; if only one product could
ever want it, it belongs to that product." Two real, current consumers,
on opposite sides of a dependency edge that forbids either from owning the
shared thing — that is precisely the case a new, lower module exists for.

## Why `lib`-only, with no NixOS module at all

Every other project in this family ships a NixOS module because every
other project's whole job is to *change what a host does*. This project's
job is the opposite: it hands back inert data (a disk image derivation, a
few device-path strings, a couple of shell-script strings) for some other
project's own test to point at. A module implies `enable`, implies a
config surface that could drift out of sync with what a *test* actually
needs, and implies this repo deciding something about a host it will never
run on. None of that is true here. `flake.nix`'s own `lib.mkEfiDisk` /
`lib.mkBrokenDisk` are plain functions — the same convention nixrescue's
own `lib.mkMaintainer` already established for exactly the same reason: a
plain function needs no module system to merge its result into whatever
called it.

The one input this flake takes is `nixpkgs`. Not `nixboot`, not
`nixrescue` — deliberately, so that the dependency graph stays a strict
line (`nixtest` ← `nixboot` ← `nixrescue`, roughly) instead of a cycle. The
one place this could have been tempting — building the trivial NixOS
toplevel this repo's own boot-proof check needs a UKI for — calls `ukify`
directly instead of going through `nixboot`'s own `extraEntries` pipeline.
Same tool, same invocation shape; no dependency on the module that wraps
it.

## Where the boundary sits between this repo and its consumers

`lib/efi-disk.nix` returns raw partitions and device paths. It does not
decide how a booted system chooses among several slots — that is
`nixrescue`'s own pointer-file-and-fallback convention, implemented as
`nixrescue`'s own `boot.initrd.postDeviceCommands` script, layered on top
of this fixture's output rather than reproduced inside it. The one
asymmetry this buys is real: `nixboot`'s own use of this fixture passes no
`slots` at all (an ESP and a UKI is the entire boot-arbitration surface it
needs to prove), while `nixrescue`'s use is the fixture's full surface.
Neither consumer pays for a concept it does not use.

`lib/broken-disk.nix` draws the same boundary a different way. It knows
how to script `cryptsetup` and a short, explicit list of `mkfs` commands;
it does not know which filesystem any particular consumer's own repair
toolchain actually carries (that catalogue is `nixfs`'s job — see
`nixfs/lib/catalogue.nix`), and it never picks a device index inside a
caller's own `virtualisation.emptyDiskImages` list (a plain size and a
plain list of kernel modules come back instead, for the caller to place
explicitly — see that file's own header for why an implicit list-merge
would be the wrong kind of convenient here).

## Why the broken-disk fixture is scripts, not a disk-image derivation

`efi-disk.nix`'s assembly runs entirely inside the Nix build sandbox
because `mtools`/`sgdisk` only ever write bytes into a plain file — no
mount, no root, no kernel module. A LUKS container with a real filesystem
*inside* it cannot be built the same way: `cryptsetup open` maps a real
`/dev/mapper/*` node through the `dm-crypt`/`dm_mod` kernel modules, which
the build sandbox has neither the privilege nor the kernel to provide.
`lib/broken-disk.nix` is therefore a pair of shell-script strings meant to
run *inside* an already-booted `nixosTest` node (a real kernel, real root,
real device-mapper) against one of that node's own extra virtio disks,
never a derivation this repo builds itself.

## Testing philosophy

A fixture library nobody has exercised is a liability, not an asset (see
the top-level README). This repo proves its own fixtures at three
different costs, on purpose:

- `checks/eval-tests.nix` — free. Every validation `throw` in both
  fixtures, forced without building anything.
- `checks/esp-contents-test.nix` — cheap. A real disk built, then read
  back apart with the same tools that built it, byte-for-byte — but no VM.
- `checks/fixtures-boot-vm-test.nix` — the expensive one, paid exactly
  once: a genuinely trivial NixOS system, packed into a UKI this repo
  builds itself (never through `nixboot`'s own module — see that file's
  header), boots through real OVMF firmware off a disk `mkEfiDisk`
  assembled, and the same VM then puts `mkBrokenDisk` through its
  format-then-rediscover round trip before the build ends.

Not tested here, and out of scope: firmware binding to real hardware (no
VM ever has any — that gap belongs to whichever consumer's own design
record accepts it and closes it with a supervised human boot instead, the
way `nixrescue`'s own `docs/design.md` already does), and any actual
consumer's own slot-selection or repair-tooling logic, which is exactly
the layer this repo's whole job is to stay underneath.
