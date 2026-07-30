# checks/default.nix
#
# Wires this project's test files into `nix flake check`:
#   eval-tests.nix              -- pure eval-time: shape, defaults, and
#                                   every validation `throw` in both
#                                   fixtures, forced without building
#                                   anything.
#   esp-contents-test.nix       -- build-time, no VM: the real bytes
#                                   `lib/efi-disk.nix` places (ESP,
#                                   extraEspFiles, every slot) extracted
#                                   back out and compared byte-for-byte.
#   purity-fixture-test.nix     -- lib/purity.nix proven in both
#                                   directions against two synthetic
#                                   tables: one genuinely pure, one
#                                   violating all four properties on
#                                   purpose. Six NixOS evals, no build.
#   fixtures-boot-vm-test.nix   -- the one check that boots anything: real
#                                   OVMF firmware, a real UKI, a real
#                                   squashfs slot, and (on the same node,
#                                   once it's up) `lib/broken-disk.nix`'s
#                                   format-then-rediscover round trip.

{ pkgs, lib, nixpkgs, mkEfiDisk, mkBrokenDisk, mkPurityChecks, system ? null }:

{
  eval-tests = import ./eval-tests.nix {
    inherit pkgs lib mkEfiDisk mkBrokenDisk;
  };

  # Kept OUT of eval-tests.nix on purpose: this one performs six full NixOS evaluations (three per
  # mkPurityChecks call, two calls), while eval-tests.nix is meant to stay instantaneous. Builds
  # nothing, boots nothing.
  purity-fixture-test = import ./purity-fixture-test.nix {
    inherit pkgs lib nixpkgs mkPurityChecks system;
  };

  esp-contents-test = import ./esp-contents-test.nix {
    inherit pkgs lib mkEfiDisk;
  };

  fixtures-boot-vm-test = import ./fixtures-boot-vm-test.nix {
    inherit pkgs lib nixpkgs mkEfiDisk mkBrokenDisk;
  };
}
