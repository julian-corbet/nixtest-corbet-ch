# checks/fixtures-boot-vm-test.nix
#
# THE PROOF THAT MATTERS: a fixture library nobody has ever exercised is a
# liability, not an asset (see this project's own top-level README). This
# is nixtest using its OWN two fixtures, together, in one disposable
# `pkgs.testers.nixosTest` VM -- nothing persists after the build, no
# standing infrastructure.
#
# `lib/efi-disk.nix`: built with exactly ONE slot and no `extraEspFiles` --
# the same strict subset nixboot's own use of this fixture needs (see that
# file's header). A single, trivial NixOS toplevel is embedded in a
# self-built UKI (via `ukify`, called directly -- see the note below on why
# this never touches nixboot's own module) and squashed straight onto that
# one slot; `/nix/store` mounts read-only, directly off it, no overlay
# needed (this system never writes to its own store, unlike a real
# rescue). Real OVMF firmware, a real ESP, a real ESP-less/pointer-less
# boot, exactly as `efi-disk.nix`'s `node` fragment promises.
#
# `lib/broken-disk.nix`: run against the SAME booted node's own extra
# virtio disk, once multi-user.target is up -- format, close, then
# rediscover cold and read the marker back. Reusing the one VM this file
# already pays to boot for both fixtures, rather than a second VM, is a
# deliberate efficiency, not a sign the two fixtures are coupled: either
# one is usable completely on its own (see `esp-contents-test.nix`, which
# never boots a VM at all, and `eval-tests.nix`, which never builds one).
#
# WHY THIS NEVER CALLS `ukify` THROUGH nixboot: nixtest sits UNDER nixboot
# (see `lib/efi-disk.nix`'s own header) and must never depend on it. `ukify`
# itself is a plain nixpkgs package (`pkgs.systemdUkify`), not a nixboot
# invention -- nixboot's own `modules/extra-entries.nix` calls the exact
# same tool the exact same way; borrowing the TECHNIQUE costs nothing,
# where depending on nixboot's MODULE would invert this family's whole
# placement rule.
#
# NOT NEEDED HERE, and deliberately absent: sshd, an operator key, an
# overlay/tmpfs-store (this system is read-only and never installs
# anything at runtime), and Nix-database registration (reaching
# `multi-user.target` needs neither -- nixosTest's own backdoor channel,
# baked into every NixOS toplevel regardless of storage backend, is what
# `machine.succeed`/`wait_for_unit` actually talk over; SSH is nixrescue's
# OWN additional concern, not a prerequisite of the test driver itself).

{ pkgs, lib, nixpkgs, mkEfiDisk, mkBrokenDisk }:

let
  makeSquashfs = pkgs.callPackage (nixpkgs + "/nixos/lib/make-squashfs.nix");
  brokenDiskFixture = mkBrokenDisk { device = "/dev/vdb"; };
in
pkgs.testers.nixosTest {
  name = "nixtest-fixtures-boot-and-broken-disk";

  nodes.machine =
    { config, lib, ... }:
    let
      # THE SELF-REFERENCE: this node's own `config.system.build.toplevel`
      # is what gets embedded in the UKI below and squashed onto its own
      # boot slot. Safe because neither derivation feeds back into
      # `environment.systemPackages` (nixboot's own extraEntries pipeline
      # would, which is exactly why ITS test needs a second, throwaway
      # eval -- see nixrescue/checks/rescue-uefi-boot-vm-test.nix's header)
      # -- here `toplevel` is only ever consumed as a plain path, inside a
      # `fileSystems.*.device` string and two `pkgs.runCommand`s that live
      # entirely outside this module's own option tree.
      toplevel = config.system.build.toplevel;

      builtUki = pkgs.runCommand "nixtest-fixtures-boot-test-uki"
        { nativeBuildInputs = [ pkgs.systemdUkify ]; }
        ''
          cmdline="init=${toplevel}/init $(cat ${toplevel}/kernel-params)"
          # `ukify` reads `/usr/lib/os-release` off the BUILD HOST by
          # default when `--os-release` is not given -- nonexistent inside
          # the build sandbox. Point it at the toplevel's own copy instead,
          # exactly nixboot's own `modules/extra-entries.nix` does.
          osrel=()
          [ -e "${toplevel}/etc/os-release" ] && osrel=(--os-release="@${toplevel}/etc/os-release")
          ukify build \
            --linux="${toplevel}/kernel" \
            --initrd="${toplevel}/initrd" \
            --cmdline="$cmdline" \
            "''${osrel[@]}" \
            --output="$out"
        '';

      rootSquashfs = makeSquashfs {
        storeContents = [ toplevel ];
        # Cheap, disposable test build -- not the production compression
        # level any real consumer's own image would want (see nixrescue's
        # `lib/mkMaintainer.nix` for that measured choice).
        comp = "zstd -Xcompression-level 3";
      };

      efiDisk = mkEfiDisk {
        inherit pkgs lib;
        ukiFile = builtUki;
        slots = [{ name = "root"; content = rootSquashfs; }];
      };

      rootStoreDevice = builtins.elemAt efiDisk.slotDevices 0;
    in
    {
      imports = [ efiDisk.node ];

      documentation.enable = false;
      documentation.nixos.enable = false;

      boot.loader.grub.enable = false;
      system.stateVersion = lib.trivial.release;

      environment.etc."nixtest-proof".text = "nixtest-fixtures-boot-proof\n";
      environment.systemPackages = [ pkgs.cryptsetup pkgs.e2fsprogs ];

      # `/nix/store` mounted DIRECTLY off the squashfs slot, read-only --
      # no overlay, unlike nixrescue's own rescue image. NixOS's own
      # default `boot.nixStoreMountOpts` (ro, nodev, nosuid) already
      # matches what a plain squashfs mount needs, so it is left untouched
      # here -- the double-remount trap nixrescue's own test found and
      # documents only bites an OVERLAY that wants to stay writable, which
      # this system never needs to be.
      boot.initrd.availableKernelModules = [ "squashfs" ];
      boot.kernelModules = brokenDiskFixture.kernelModules;

      fileSystems."/" = {
        fsType = "tmpfs";
        device = "none";
        options = [ "mode=0755" ];
      };
      fileSystems."/nix/store" = {
        device = rootStoreDevice;
        fsType = "squashfs";
        options = [ "ro" ];
        neededForBoot = true;
      };

      virtualisation.memorySize = 1024;
      virtualisation.cores = 2;
      # vdb: the synthetic broken disk `lib/broken-disk.nix` formats and
      # rediscovers below, once this node itself is up.
      virtualisation.emptyDiskImages = [ brokenDiskFixture.diskSizeMiB ];

      system.build.nixtestDiskImage = efiDisk.diskImage;
    };

  testScript =
    { nodes, ... }:
    ''
      import os
      import shutil

      disk_image = "${nodes.machine.system.build.nixtestDiskImage}/disk.img"
      root_store_device = "${nodes.machine.fileSystems."/nix/store".device}"

      tmp_dir = os.environ.get("TMPDIR", "/tmp")
      tmp_disk = os.path.join(tmp_dir, "nixtest-fixtures-boot-disk.img")
      shutil.copy(disk_image, tmp_disk)
      os.chmod(tmp_disk, 0o600)
      os.environ["NIX_DISK_IMAGE"] = tmp_disk

      machine.start()
      machine.wait_for_unit("multi-user.target")

      with subtest("real UEFI firmware booted the disk lib/efi-disk.nix assembled: this system's own marker is present"):
          machine.succeed("grep -q nixtest-fixtures-boot-proof /etc/nixtest-proof")

      with subtest("/nix/store is genuinely the squashfs slot, mounted read-only, not merely rendered so"):
          src = machine.succeed(
              "findmnt -no SOURCE --target /nix/store"
          ).strip().splitlines()[0]
          assert src == root_store_device, (
              f"expected /nix/store mounted from {root_store_device}, findmnt reported: {src}"
          )
          fstype = machine.succeed(
              "findmnt -no FSTYPE --target /nix/store"
          ).strip().splitlines()[0]
          assert fstype == "squashfs", f"expected /nix/store to be squashfs, got fstype={fstype}"
          machine.fail("touch /nix/store/nixtest-ro-probe")

      with subtest("lib/broken-disk.nix: format a synthetic LUKS+ext4 disk, then rediscover it cold"):
          machine.succeed("test -b /dev/vdb")
          machine.succeed("""${brokenDiskFixture.formatScript}""")
          machine.succeed("""${brokenDiskFixture.rediscoverScript}""")
    '';
}
