# checks/eval-tests.nix
#
# EVAL-TIME tests only: the shape and validation logic of both fixtures,
# checked without ever invoking a builder. Forcing a derivation's own
# attribute set (`builtins.deepSeq`) is enough to trip every `throw` in
# `lib/efi-disk.nix` and `lib/broken-disk.nix` -- both live inside plain
# string interpolation that Nix must evaluate to construct the derivation's
# arguments, well before anything is actually built. See
# `esp-contents-test.nix` for the one check that actually builds a disk and
# inspects its bytes, and `fixtures-boot-vm-test.nix` for the one that
# boots it.

{ pkgs, lib, mkEfiDisk, mkBrokenDisk }:

let
  check = name: ok: detail: { inherit name ok detail; };

  evalFails = thunk: !(builtins.tryEval (builtins.deepSeq thunk true)).success;

  fakeUki = pkgs.writeText "fake-uki" "not a real UKI, only used to check mkEfiDisk's own shape";
  fakeSlotA = pkgs.writeText "fake-slot-a" "stand-in slot content";

  diskNoSlots = mkEfiDisk { inherit pkgs lib; ukiFile = fakeUki; };

  diskWithSlots = mkEfiDisk {
    inherit pkgs lib;
    ukiFile = fakeUki;
    extraEspFiles = { "EFI/nixtest/marker" = pkgs.writeText "marker" "hello"; };
    slots = [
      { name = "slot-a"; content = fakeSlotA; }
      { name = "slot-b"; sizeMiB = 4; } # deliberately empty/corrupt: no content
    ];
  };

  brokenDiskDefault = mkBrokenDisk { };
  brokenDiskCustom = mkBrokenDisk {
    device = "/dev/vdc";
    filesystem = "btrfs";
    markerContent = "custom-marker";
  };

  results = [
    (check "mkEfiDisk with no slots: espDevice is partition 1"
      (diskNoSlots.espDevice == "/dev/vda1")
      "espDevice should always be /dev/vda1")

    (check "mkEfiDisk with no slots: slotDevices is empty -- nixboot's own strict-subset use"
      (diskNoSlots.slotDevices == [ ])
      "no slots passed in should mean no slot devices back out")

    (check "mkEfiDisk with no slots: node fragment sets the three firmware-boot settings"
      (diskNoSlots.node.virtualisation.useEFIBoot
        && diskNoSlots.node.virtualisation.directBoot.enable == false
        && diskNoSlots.node.virtualisation.mountHostNixStore == false)
      "node should force useEFIBoot on and directBoot/mountHostNixStore off")

    (check "mkEfiDisk with two slots: slotDevices are partitions 2 and 3, in order"
      (diskWithSlots.slotDevices == [ "/dev/vda2" "/dev/vda3" ])
      "slot order should map directly to ascending partition numbers, starting after the ESP")

    (check "mkEfiDisk: a slot with neither content nor sizeMiB fails to evaluate"
      (evalFails (mkEfiDisk {
        inherit pkgs lib;
        ukiFile = fakeUki;
        slots = [{ name = "broken-slot"; }];
      }).diskImage)
      "a slot needs content, an explicit sizeMiB, or both -- neither should throw before any bytes are built")

    (check "mkEfiDisk: diskImage is a real derivation, not forced to build here"
      (diskWithSlots.diskImage ? drvPath || diskWithSlots.diskImage ? outPath)
      "the returned diskImage should be an ordinary derivation")

    (check "mkBrokenDisk: default device/filesystem"
      (brokenDiskDefault.device == "/dev/vdb" && brokenDiskDefault.diskSizeMiB == 300)
      "defaults documented in lib/broken-disk.nix should hold")

    (check "mkBrokenDisk: kernelModules is a plain, mergeable list"
      (brokenDiskDefault.kernelModules == [ "dm-crypt" "dm_mod" ])
      "dm-crypt and dm_mod are the two modules a LUKS-backed test node needs")

    (check "mkBrokenDisk: formatScript references the declared device and marker"
      (lib.hasInfix "/dev/vdb" brokenDiskDefault.formatScript
        && lib.hasInfix "hello-from-nixtest-broken-disk" brokenDiskDefault.formatScript)
      "formatScript should be built from the caller's own device/markerContent, not a hard-coded stand-in")

    (check "mkBrokenDisk: custom filesystem selects the matching mkfs command"
      (lib.hasInfix "mkfs.btrfs" brokenDiskCustom.formatScript)
      "filesystem = \"btrfs\" should select mkfs.btrfs, not the ext4 default")

    (check "mkBrokenDisk: rediscoverScript asserts against the declared device, not a wildcard"
      (lib.hasInfix "custom-marker" brokenDiskCustom.rediscoverScript
        && lib.hasInfix "/dev/vdc" brokenDiskCustom.rediscoverScript)
      "rediscoverScript should assert blkid found exactly the device this fixture was pointed at")

    (check "mkBrokenDisk: an unknown filesystem fails to evaluate, not silently mkfs's nothing"
      (evalFails (mkBrokenDisk { filesystem = "not-a-real-filesystem"; }).formatScript)
      "an unrecognised filesystem name should throw with the known-names list, not build a broken script")
  ];

  failed = builtins.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
if failed != [ ]
then
  throw ''
    nixtest eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
    ${report}
  ''
else
  pkgs.runCommand "nixtest-eval-tests"
    { passedCount = toString (builtins.length results); }
    ''
      echo "all $passedCount nixtest eval tests passed"
      touch $out
    ''
