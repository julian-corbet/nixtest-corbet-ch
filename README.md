# nixtest

Shared NixOS test **fixtures** for this project family — never a runner.
Three, so far:

- **`lib.mkEfiDisk`** (`lib/efi-disk.nix`) — assembles a raw GPT disk with a
  populated EFI System Partition, entirely inside the ordinary Nix build
  sandbox: no mount, no root, no kernel module, because `mtools` and
  `sgdisk` only ever touch a plain file. Optionally carves any number of
  raw "slot" partitions after the ESP too, each `dd`'d with its own
  content (or left an intentionally zero-filled hole). Returns the disk
  image derivation, the device paths for the ESP and every slot, and a
  small NixOS-module fragment (`useEFIBoot`, `directBoot.enable = false`,
  `mountHostNixStore = false`) that makes a `pkgs.testers.nixosTest` node
  boot that exact disk through **real OVMF UEFI firmware** — no boot-menu
  entries required, ever, since the UKI lands at the UEFI
  removable-media fallback path.

- **`lib.mkBrokenDisk`** (`lib/broken-disk.nix`) — the other reusable
  fixture, of a genuinely different shape: a pair of shell scripts (never
  executed by this repo itself) that format a synthetic LUKS-plus-filesystem
  container on one of a booted VM's own extra virtio disks, and rediscover
  it cold by `blkid` type alone — the actual "find a disk pulled off a dead
  machine" scenario a rescue or repair-tooling module's own test wants to
  drive.

- **`lib.mkPurityChecks`** (`lib/purity.nix`) — the odd one out: it tests a
  *caller's own module* rather than assembling a disk. Given a module file
  that claims to be a pure-data table, it proves the claim four ways — the
  module binds no `pkgs` argument (via `builtins.functionArgs`, which a
  module cannot dodge by renaming); composing it alone against a bare stub
  system changes no watched surface (an **eval diff**, so an *indirect*
  write that expands into a unit or a package cannot slip past a text
  scan); its source never names the guarded option paths; and every fact it
  publishes is plain data, reported per offending attribute. Declaring
  `options` and `config.assertions` is explicitly not a violation — a table
  that validates itself and hands back facts is what "pure data" means.

  Each proof ships with a **meta-test**: a decoy module that genuinely
  commits the violation, so every comparison is shown capable of failing
  rather than assumed to work. `checks/purity-fixture-test.nix` runs the
  whole thing in both directions against two synthetic tables (16
  assertions, no build).

  Why it matters beyond tidiness: a module that is pure data is one whose
  facts can be read — by a tool, a renderer, an audit — without evaluating
  a system around them. A fact welded into a `systemd` unit's script can
  only be recovered by evaluating *and then text-parsing* a derivation.

## Why this exists

`nixrescue`'s own UEFI boot test (`checks/rescue-uefi-boot-vm-test.nix`)
built the disk-assembly harness first, to prove its own boot chain.
`nixboot` — the boot-arbitration layer nixrescue sits *in front of* —
needs exactly the same harness to test its own `nixboot.extraEntries`
pipeline, and nixboot is the **lower** layer: nixboot depending on
nixrescue to borrow a test fixture would invert the dependency arrow this
family's whole placement rule is built on ("if two products would want it,
it is a module; if only one product could ever want it, it belongs to
that product"). Two real consumers wanting the identical mechanism, with
the dependency graph forbidding either from owning it, is exactly what
moves something out into its own thing.

## What this deliberately is not

**No NixOS module. No `enable`. No systemd unit. Nothing that acts on a
host.** This is a `lib`-only flake — plain functions, called with `pkgs`
(and, for the disk-assembly fixture, `lib`) supplied directly by whatever
evaluation needs them, the same convention nixrescue's own
`lib.mkMaintainer` already uses. Execution belongs to CI (or to whichever
project's own `checks` composes these fixtures into an actual test), never
to this repo — see `flake.nix`'s own `inputs` for how far that goes: this
flake depends on nothing but `nixpkgs`, so that neither nixboot nor
nixrescue can ever end up depending on *it* depending on *them*.

## Quickstart

```nix
{
  inputs.nixtest.url = "github:julian-corbet/nixtest-corbet-ch";
}
```

```nix
# inside your own checks/whatever-vm-test.nix
{ pkgs, lib, nixtest, ... }:
let
  efiDisk = nixtest.lib.mkEfiDisk {
    inherit pkgs lib;
    ukiFile = myBuiltUki; # any single .efi payload
    # slots left at its default ([]) -- an ESP and a UKI is everything a
    # boot-arbitration test needs; nixboot's own use stops exactly here.
  };
in
pkgs.testers.nixosTest {
  name = "my-own-uefi-boot-test";
  nodes.machine = { lib, ... }: {
    imports = [ efiDisk.node ];
    # ...your own fileSystems, matching whatever you put on the disk...
  };
  testScript = ''
    # substitute NIX_DISK_IMAGE with ${efiDisk.diskImage}/disk.img, then
    # machine.start(); machine.wait_for_unit("multi-user.target"); ...
  '';
}
```

A rescue-style consumer that also needs several raw payload partitions
passes `slots = [ { name = "slot-a"; content = ...; } { name = "slot-b"; ... } ]`
and decides its own slot-selection logic (which pointer file, which
fallback rule) entirely on its own side — see `lib/efi-disk.nix`'s own
header for exactly where that boundary sits.

```nix
let
  broken = nixtest.lib.mkBrokenDisk { device = "/dev/vdb"; filesystem = "ext4"; };
in
{
  # merge broken.kernelModules into your own boot.kernelModules, and
  # broken.diskSizeMiB into your own virtualisation.emptyDiskImages, then
  # in testScript: machine.succeed(broken.formatScript); ... reboot or
  # not ...; machine.succeed(broken.rediscoverScript);
}
```

## Testing this repo itself

`nix flake check` runs three things: `checks/eval-tests.nix` (pure
eval-time — every validation `throw` in both fixtures, forced without
building anything), `checks/esp-contents-test.nix` (build-time, no VM —
the actual bytes `mkEfiDisk` places, extracted back out with the same
tools and compared byte-for-byte against what this check handed it), and
`checks/fixtures-boot-vm-test.nix` (the one check that boots anything: a
trivial NixOS toplevel, packed into a self-built UKI via `ukify` called
directly — never through nixboot's own module, see that file's header —
squashed onto a single slot, and booted through real OVMF firmware; the
same VM then formats and rediscovers a synthetic broken disk via
`mkBrokenDisk`, once it's up). A fixture library nobody has exercised is a
liability, not an asset.
