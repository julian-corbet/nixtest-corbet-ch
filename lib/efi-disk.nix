# lib/efi-disk.nix
#
# THE FIXTURE, lifted out of nixrescue's own UEFI boot test
# (checks/rescue-uefi-boot-vm-test.nix) and generalised. That file's own
# header already carries the full boot-chain rationale -- UKI at the UEFI
# REMOVABLE-MEDIA fallback path, the disk-substitution technique copied
# verbatim from nixpkgs' own `nixos/tests/qemu-vm-external-disk-image.nix`,
# why the assembly needs no mount and no root (mtools + sgdisk write bytes
# straight into a raw file, so this runs inside the ordinary Nix build
# sandbox). This file does not repeat that reasoning; it is the same
# mechanism, with nixrescue's OWN concerns (which pointer file, which slot
# resolution script, which "current" convention) stripped back out.
#
# WHY THIS MOVED HERE, NOT SIDEWAYS INTO nixboot OR DOWN INTO A THIRD COPY:
# nixboot needs exactly the same thing nixrescue's harness already proved --
# a disk with a real ESP holding a real UKI, booted through real OVMF
# firmware with no boot-manager NVRAM entries -- to test its OWN
# `nixboot.extraEntries` pipeline end to end. nixboot is the LOWER layer (a
# rescue sits IN FRONT OF a main's boot chain; the boot chain is nixboot's
# job, not nixrescue's), so nixboot depending on nixrescue to get it would
# invert the arrow this family's whole placement rule is built on. Two
# projects wanting the same fixture is exactly the "if two products would
# want it, it is a module" case -- except a NixOS module is precisely what
# this must NOT become (see this flake's own top-level README): nothing
# here runs on a host, nothing here has an `enable`, and nothing here
# decides what a consumer's test actually asserts once the disk boots.
#
# THE ONE DELIBERATE ASYMMETRY: slots are optional, and a caller that never
# mentions them pays nothing for the concept. nixboot's own use of this
# fixture is a strict subset of nixrescue's -- an ESP and a UKI is the
# entire boot-arbitration surface nixboot needs to prove; deciding WHICH of
# several cold-mode payload partitions to mount (nixrescue's own
# pointer-file convention and fallback-on-bad-pointer logic) is nixrescue's
# domain-specific mechanism, layered on top of this fixture's raw
# partitions by nixrescue's OWN `boot.initrd.postDeviceCommands` script, not
# reproduced here. This file hands back device paths and raw bytes; it does
# not decide how a booted system chooses among them.
#
# WHAT THE RETURNED `node` FRAGMENT IS, AND ISN'T: exactly the three
# settings that make a nixosTest node boot a PRE-BUILT external disk image
# through real firmware instead of the ephemeral, host-store-shared disk
# `qemu-vm.nix` would otherwise assemble for it --
# `virtualisation.useEFIBoot`, `virtualisation.directBoot.enable = false`,
# `virtualisation.mountHostNixStore = false` -- plus forcing
# `virtualisation.fileSystems` empty so the caller's OWN `fileSystems.*`
# (root, `/nix/store`, whatever the disk this function built actually
# holds) are the sole source, not qemu-vm.nix's default auto-mounts. It is
# NOT the slot-selection initrd logic, and it is NOT
# `boot.initrd.availableKernelModules` -- both depend on what the caller put
# on the disk (a squashfs slot needs `squashfs`; nixboot's own test needs
# none of this at all, since it never mounts anything off this disk from
# inside Linux -- the firmware alone reads the ESP). Merging `node` is
# always safe: every field it sets is a plain value, never a list a second
# module might also want to contribute to, so there is nothing for a
# caller's own settings to silently lose by importing it.
#
# WHY THE UKI ALWAYS LANDS AT THE REMOVABLE-MEDIA FALLBACK PATH
# (\EFI\BOOT\BOOTX64.EFI), NOT A PARAMETER: every consumer of this fixture
# is, by construction, booting a disk nobody has ever seen -- a fresh OVMF
# NVRAM store, every single run. The fallback path is the one UEFI firmware
# tries with zero boot-manager entries, which is exactly and only this
# situation. A real host that owns its own ESP and wants normal
# auto-discovery is not this fixture's use case at all (that is
# `nixboot.extraEntries`'s own `EFI/Linux/<name>.efi` placement, a
# genuinely different concern -- registering a *permanent* boot artifact on
# a host that already has firmware state, not standing up a *disposable*
# one for a test that starts from none).

{ pkgs
, lib
, ukiFile # A single built UKI (or any one .efi payload) -- placed at the
  # UEFI removable-media fallback path. Build it however the caller likes;
  # this fixture does not build or sign one itself (see this file's own
  # header on why nixboot's `ukify`/`sbsign` pipeline stays out of here).
, espSizeMiB ? null # Override the ESP's size. Left null (the default), the
  # size is computed at BUILD time from the actual bytes of `ukiFile` plus
  # every `extraEspFiles` entry, with 16 MiB headroom -- the same headroom
  # nixrescue's own original harness used, chosen empirically there and
  # kept here rather than re-guessed.
, extraEspFiles ? { } # Attrset of ESP-relative path -> a file or derivation
  # to place there via `mcopy`, e.g. `{ "EFI/nixrescue/current" =
  # pkgs.writeText "pointer" "slot-b"; }`. This fixture names no
  # consumer-specific path itself -- nixrescue's own pointer-file
  # convention belongs to nixrescue, not here. Every needed parent
  # directory (`EFI`, `EFI/nixrescue`, ...) is created automatically.
, slots ? [ ] # Optional list of `{ name, sizeMiB ? null, content ? null }`.
  # Each becomes its own raw GPT partition placed after the ESP, in the
  # order given. `content`, if set, is `dd`'d onto the partition verbatim
  # (a squashfs, or any other raw image); its size is auto-computed the
  # same way the ESP's is, with 16 MiB headroom, unless `sizeMiB` overrides
  # it. Leaving `content` null needs an explicit `sizeMiB` -- the partition
  # then stays exactly as `truncate` made it: a sparse, zero-filled hole,
  # i.e. an intentionally invalid/absent slot, useful for a
  # fallback-on-bad-slot test. nixboot's own use passes no slots at all.
}:

let
  # ── slot normalisation + validation, at eval time (fail before any bytes
  #    get built). `slots` is a plain list of attrsets, not a submodule, so
  #    `content`/`sizeMiB` are filled in here rather than required on every
  #    entry -- everything downstream can then trust both keys exist. ─────
  slotsChecked = lib.imap1
    (i: rawSlot:
      let slot = { content = null; sizeMiB = null; } // rawSlot; in
      if slot.content == null && slot.sizeMiB == null then
        throw "nixtest.mkEfiDisk: slots.${toString (i - 1)} (\"${slot.name}\") has neither `content` nor `sizeMiB` -- a deliberately-empty/corrupt slot still needs an explicit size; a real slot's size can instead be left to auto-compute from its `content`."
      else
        slot)
    slots;

  # ── size expressions: a plain number when the caller overrides, a
  #    build-time `stat`-driven arithmetic expansion otherwise. Either form
  #    is a valid bare operand inside a bash `$(( ... ))` context or right
  #    after a `+` in an sgdisk `-n` argument, so callers of this
  #    expression never need to know which case they got. ─────────────────
  byteSumExpr = files: "(0" + lib.concatMapStrings (f: " + $(stat -c%s ${f})") files + ")";
  mibExpr = { override, byteFiles }:
    if override != null
    then toString override
    else "$(( ${byteSumExpr byteFiles} / 1048576 + 16 ))";

  espSizeExpr = mibExpr {
    override = espSizeMiB;
    byteFiles = [ ukiFile ] ++ lib.attrValues extraEspFiles;
  };

  # ── every directory that has to exist on the ESP before mcopy can place
  #    a file into it, shallowest first so `mmd` never has to guess ─────────
  dirAncestors = path:
    let
      parts = lib.filter (s: s != "") (lib.splitString "/" path);
      n = lib.length parts;
    in
    lib.genList (i: lib.concatStringsSep "/" (lib.take (i + 1) parts)) (if n == 0 then 0 else n - 1);

  espTargets = [ "EFI/BOOT/BOOTX64.EFI" ] ++ lib.attrNames extraEspFiles;
  neededEspDirs =
    lib.sort (a: b: lib.length (lib.splitString "/" a) < lib.length (lib.splitString "/" b))
      (lib.unique (lib.concatMap dirAncestors espTargets));

  slotPartNum = i: i + 1; # partition 1 is always the ESP

  slotSizeDecls = lib.concatStrings (lib.imap1
    (i: slot: ''
      slotSizeMiB${toString i}=${mibExpr {
        override = slot.sizeMiB;
        byteFiles = lib.optional (slot.content != null) slot.content;
      }}
    '')
    slotsChecked);

  partitionDecls = lib.concatStrings (lib.imap1
    (i: slot: ''
      sgdisk -n "${toString (slotPartNum i)}:0:+''${slotSizeMiB${toString i}}MiB" -t ${toString (slotPartNum i)}:8300 -c ${toString (slotPartNum i)}:${lib.escapeShellArg slot.name} disk.img
    '')
    slotsChecked);

  ddDecls = lib.concatStrings (lib.imap1
    (i: slot:
      let partNum = slotPartNum i; in
      ''
        p${toString partNum}=$(sgdisk -i ${toString partNum} disk.img | awk '/^First sector:/ {print $3}')
      '' + (
        if slot.content != null then ''
          dd if=${slot.content} of=disk.img bs=512 seek="$p${toString partNum}" conv=notrunc status=none
        '' else ''
          echo "nixtest mkEfiDisk: slot '${slot.name}' (partition ${toString partNum}) left zero-filled on purpose -- no content given, i.e. an intentionally corrupt/absent slot" 1>&2
        ''
      ))
    slotsChecked);

  # NOTE: the per-slot piece below is built as an INDENTED (''...'') string
  # specifically so `''$` can escape the literal `${` a bash reference
  # needs -- that escape means something different (nothing at all useful)
  # inside a plain double-quoted "..." string, where the escape would
  # instead have to be `\$`. Concatenating already-built plain strings
  # together afterwards (as below) needs no further escaping either way,
  # since interpolating a STRING VALUE just inserts its characters
  # verbatim, never re-parses them.
  slotSizeRefsBash = lib.concatStrings (lib.imap1
    (i: _: '' + ''${slotSizeMiB${toString i}}'')
    slotsChecked);

  diskSizeExpr = "$(( 2 + ${espSizeExpr}${slotSizeRefsBash} ))";

  espDirDecls = lib.concatMapStringsSep "\n" (d: "mmd -i esp.img ::${d}") neededEspDirs;
  extraEspFileCopies = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (dest: src: "mcopy -i esp.img ${src} ::${dest}") extraEspFiles);

  diskImage = pkgs.runCommand "nixtest-efi-disk"
    {
      nativeBuildInputs = [ pkgs.gptfdisk pkgs.dosfstools pkgs.mtools pkgs.gawk pkgs.coreutils ];
    }
    ''
      set -euo pipefail

      espSizeMiB=${espSizeExpr}
      ${slotSizeDecls}

      truncate -s "''${espSizeMiB}MiB" esp.img
      mkfs.vfat -F32 -n NIXTEST esp.img
      ${espDirDecls}
      mcopy -i esp.img ${ukiFile} ::EFI/BOOT/BOOTX64.EFI
      ${extraEspFileCopies}

      diskSizeMiB=${diskSizeExpr}
      truncate -s "''${diskSizeMiB}MiB" disk.img

      sgdisk -o disk.img
      sgdisk -n "1:0:+''${espSizeMiB}MiB" -t 1:ef00 -c 1:NIXTEST-ESP disk.img
      ${partitionDecls}
      sgdisk -p disk.img 1>&2

      p1=$(sgdisk -i 1 disk.img | awk '/^First sector:/ {print $3}')
      dd if=esp.img of=disk.img bs=512 seek="$p1" conv=notrunc status=none

      ${ddDecls}

      mkdir -p $out
      mv disk.img $out/disk.img
    '';
in
{
  inherit diskImage;

  espDevice = "/dev/vda1";
  slotDevices = lib.imap1 (i: _: "/dev/vda${toString (slotPartNum i)}") slotsChecked;

  # Merge into a nixosTest node, e.g. `nodes.machine = { imports = [
  # thisResult.node ... ]; ... };` -- see this file's own header for
  # exactly what it does and does not cover.
  node = {
    virtualisation.useEFIBoot = true;
    virtualisation.directBoot.enable = false;
    virtualisation.mountHostNixStore = false;
    virtualisation.fileSystems = lib.mkForce { };
  };
}
