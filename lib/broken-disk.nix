# lib/broken-disk.nix
#
# THE OTHER REUSABLE FIXTURE, of a genuinely different shape than
# `efi-disk.nix`. That fixture assembles real bytes onto a disk INSIDE the
# Nix build sandbox -- no mount, no root, no kernel module, because mtools
# and sgdisk only ever touch a plain file. A LUKS container with a real
# filesystem inside it cannot be built the same way: writing the LUKS
# header itself needs no device-mapper, but making a filesystem live
# *inside* the opened container does -- `cryptsetup open` maps a real
# `/dev/mapper/*` node via the `dm-crypt`/`dm_mod` kernel modules, which the
# build sandbox has neither the privilege nor the kernel to provide. So
# this fixture is not a disk-image derivation at all: it is a pair of
# shell scripts meant to run INSIDE an already-booted nixosTest node (which
# is a real kernel, real root, real device-mapper) against one of that
# node's own extra virtio disks.
#
# THE SHAPE THIS TAKES ON PURPOSE: plain data (a size to add to the
# caller's own `virtualisation.emptyDiskImages`, a list of kernel modules
# to add to `boot.kernelModules`, and two script strings), never a merged
# "node" fragment the way `efi-disk.nix`'s `node` is. `emptyDiskImages` is
# a LIST every module contributes to -- which device index a given entry
# lands at depends on the final concatenation order across every module
# that touches it, which this fixture cannot see or control from in here.
# Handing back a bare size and letting the caller place it explicitly in
# their own list is what keeps device-index assignment visible at the call
# site instead of an implicit merge order a reader would have to trace
# through several files to reconstruct.
#
# WHAT THIS DELIBERATELY DOES NOT DECIDE: which filesystem. A rescue or
# repair-tooling module's own test knows which filesystems its OWN
# toolchain actually carries (that catalogue is nixfs's job, not this
# one -- see nixfs/lib/catalogue.nix); this fixture only knows how to
# script `mkfs.<x>` for a short, explicit list of common choices, and
# throws a clear error for anything else rather than guessing a package to
# depend on. The caller is responsible for making sure the `mkfs` tool (and
# `cryptsetup` itself) are actually present on the node this runs against --
# same boundary `efi-disk.nix` draws by never picking what a slot's
# content actually is.
#
# THE TWO SCRIPTS ARE THE TWO HALVES OF THE SAME PROOF nixrescue's own
# `checks/rescue-vm-test.nix` already established inline: `formatScript`
# creates the container fresh (as if this were the moment before a disk
# went into a drawer), and `rediscoverScript` finds it FROM SCRATCH by
# `blkid` type alone, unlocks it, and reads the marker back -- the actual
# rescue scenario, not merely "the thing I just made still opens". Neither
# script calls `machine.succeed` itself; that stays the calling test's job
# (see this flake's own top-level README on why nixtest is fixtures, never
# a runner).

{ device ? "/dev/vdb"
, filesystem ? "ext4"
, passphrase ? "nixtest-broken-disk-passphrase"
, mapperName ? "nixtest-broken-disk"
, mountPoint ? "/mnt/nixtest-broken-disk"
, markerName ? "proof.txt"
, markerContent ? "hello-from-nixtest-broken-disk"
, diskSizeMiB ? 300
}:

let
  mkfsCommands = {
    ext2 = "mkfs.ext2 -F";
    ext3 = "mkfs.ext3 -F";
    ext4 = "mkfs.ext4 -F";
    btrfs = "mkfs.btrfs -f";
    xfs = "mkfs.xfs -f";
    vfat = "mkfs.vfat";
  };
  knownFilesystemNames = builtins.concatStringsSep ", " (builtins.attrNames mkfsCommands);
  mkfsCommand = mkfsCommands.${filesystem} or (throw
    "nixtest.mkBrokenDisk: no mkfs command known for filesystem '${filesystem}' -- pass one of ${knownFilesystemNames} (or extend the list in lib/broken-disk.nix)");
in
{
  inherit device diskSizeMiB;

  # Add to the caller's own `boot.kernelModules` -- a plain list, safe to
  # concatenate (`++`) with whatever else the node already needs.
  kernelModules = [ "dm-crypt" "dm_mod" ];

  # `diskSizeMiB` above is what to add to the caller's own
  # `virtualisation.emptyDiskImages` (a plain int, in MiB) -- see this
  # file's own header for why this fixture never picks the device index
  # itself.

  # Run via `machine.succeed(fixture.formatScript)` (or split across
  # several `with subtest(...):` blocks by copying individual lines --
  # this is a plain multi-line shell script, not an opaque blob).
  formatScript = ''
    set -euo pipefail
    test -b ${device}
    echo -n '${passphrase}' | cryptsetup luksFormat --type luks2 --batch-mode ${device} -
    echo -n '${passphrase}' | cryptsetup open ${device} ${mapperName} -
    ${mkfsCommand} /dev/mapper/${mapperName}
    mkdir -p ${mountPoint}
    mount /dev/mapper/${mapperName} ${mountPoint}
    echo '${markerContent}' > ${mountPoint}/${markerName}
    umount ${mountPoint}
    cryptsetup close ${mapperName}
  '';

  # The actual rescue scenario: rediscover the container cold, with no
  # assumption left over from having just created it -- `blkid` alone
  # decides the device, asserted to still be the one this fixture was
  # pointed at.
  rediscoverScript = ''
    set -euo pipefail
    found=$(blkid -t TYPE=crypto_LUKS -o device)
    if [ "$found" != "${device}" ]; then
      echo "nixtest broken-disk: expected to rediscover the LUKS container at ${device}, blkid found: $found" >&2
      exit 1
    fi
    echo -n '${passphrase}' | cryptsetup open "$found" ${mapperName} -
    mkdir -p ${mountPoint}
    mount /dev/mapper/${mapperName} ${mountPoint}
    grep -qF '${markerContent}' ${mountPoint}/${markerName}
    umount ${mountPoint}
    cryptsetup close ${mapperName}
  '';
}
