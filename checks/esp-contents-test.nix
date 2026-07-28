# checks/esp-contents-test.nix
#
# BUILD-TIME, no VM: proves `lib/efi-disk.nix` actually places the right
# bytes at the right offsets, rather than merely evaluating without error
# (eval-tests.nix's own job). Extracts the ESP and every slot partition
# straight back out of the assembled `disk.img` with the same tools
# (`sgdisk`, `mtools`) the fixture used to build it, and compares against
# the exact source files this check handed the fixture -- a genuine
# round-trip, not a rendering check. Exercises `extraEspFiles` in
# particular, which `fixtures-boot-vm-test.nix` deliberately does not (that
# check's whole point is the single-slot firmware-boot path; the ESP never
# gets mounted from inside that VM at all, since real firmware reads it
# directly).

{ pkgs, lib, mkEfiDisk }:

let
  ukiContent = pkgs.writeText "esp-contents-test-uki" "stand-in UKI bytes -- this check never boots anything, only verifies placement";
  markerContent = pkgs.writeText "esp-contents-test-marker" "extra-esp-file-content";
  slotAContent = pkgs.writeText "esp-contents-test-slot-a" "slot-a-real-content-bytes";

  disk = mkEfiDisk {
    inherit pkgs lib;
    ukiFile = ukiContent;
    extraEspFiles = { "EFI/nixtest/marker" = markerContent; };
    slots = [
      { name = "slot-a"; content = slotAContent; }
      { name = "slot-b"; sizeMiB = 2; } # no content: must come back all zero
    ];
  };
in
pkgs.runCommand "nixtest-efi-disk-contents-test"
{
  nativeBuildInputs = [ pkgs.gptfdisk pkgs.mtools pkgs.gawk pkgs.coreutils pkgs.diffutils ];
}
  ''
    set -euo pipefail
    cp ${disk.diskImage}/disk.img disk.img
    chmod +w disk.img

    extractPartition() {
      # $1 = partition number, $2 = output file
      local first size
      first=$(sgdisk -i "$1" disk.img | awk '/^First sector:/ {print $3}')
      size=$(sgdisk -i "$1" disk.img | awk '/^Partition size:/ {print $3}')
      dd if=disk.img of="$2" bs=512 skip="$first" count="$size" status=none
    }

    echo "── ESP (partition 1): the UKI landed at the removable-media path ──"
    extractPartition 1 esp.img
    mcopy -n -i esp.img ::EFI/BOOT/BOOTX64.EFI extracted-uki
    cmp ${ukiContent} extracted-uki

    echo "── ESP: extraEspFiles landed at their declared path ──"
    mcopy -n -i esp.img ::EFI/nixtest/marker extracted-marker
    cmp ${markerContent} extracted-marker

    echo "── slot-a (partition 2): real content, dd'd verbatim ──"
    extractPartition 2 slot-a.img
    slotAContentSize=$(stat -c%s ${slotAContent})
    cmp -n "$slotAContentSize" ${slotAContent} slot-a.img

    echo "── slot-b (partition 3): no content given -- must be genuinely zero-filled, not garbage ──"
    extractPartition 3 slot-b.img
    slotBSize=$(stat -c%s slot-b.img)
    cmp <(head -c "$slotBSize" /dev/zero) slot-b.img

    echo "── slotDevices/espDevice match the partition numbering this check just verified ──"
    test "${disk.espDevice}" = "/dev/vda1"
    test "${builtins.elemAt disk.slotDevices 0}" = "/dev/vda2"
    test "${builtins.elemAt disk.slotDevices 1}" = "/dev/vda3"

    touch $out
  ''
