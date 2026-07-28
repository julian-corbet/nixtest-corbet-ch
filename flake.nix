{
  description = "nixtest - shared NixOS test FIXTURES for this project family: a raw-disk/UEFI-boot harness and a synthetic broken-disk harness, neither of them a runner.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # NOTHING ELSE. nixtest sits UNDER both nixboot and nixrescue in this
    # family's dependency order (see lib/efi-disk.nix's own header) -- it
    # must never depend on either, or the arrow this whole family's
    # placement rule is built on inverts. This flake's own `checks` prove
    # its fixtures against nixpkgs primitives directly (a plain
    # `nixosSystem` eval, `pkgs.systemdUkify`'s `ukify` tool called
    # directly), never against nixboot's or nixrescue's own modules.
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # ── Plain functions, not NixOS modules -- see the top-level README ──
      # for why this flake has no `nixosModules` at all. Each takes `pkgs`
      # (and, for the disk-assembly fixture, `lib`) directly from whatever
      # evaluation calls it, exactly the `lib.mkMaintainer` convention
      # nixrescue's own flake already uses for the same reason: a plain
      # function needs no module system to merge its result into a
      # caller's own config.
      lib = {
        mkEfiDisk = import ./lib/efi-disk.nix;
        mkBrokenDisk = import ./lib/broken-disk.nix;
      };

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system;
          mkEfiDisk = self.lib.mkEfiDisk;
          mkBrokenDisk = self.lib.mkBrokenDisk;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
