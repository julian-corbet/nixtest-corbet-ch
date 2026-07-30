# checks/fixtures/impure-table.nix
#
# The DECOY TABLE: a module that looks like a fact table and is not one. It exists solely so
# `lib/purity.nix`'s self-test can prove the fixture actually FAILS a violator, rather than only
# that it passes a compliant module -- a check never shown capable of failing is an assumption
# wearing a proof's clothes.
#
# It violates all four properties deliberately, one per line below, so a self-test can name which
# check should fire and be wrong if it doesn't:
#
#   1. binds `pkgs`                          -> no-pkgs-argument
#   2. writes `systemd.services`             -> alone-never-changes-systemd.services
#                                               + source-never-mentions-systemd.services
#   3. writes `environment.systemPackages`   -> the same pair for that surface
#   4. publishes a derivation as a "fact"    -> <path>-is-serialisable-data
#
# Violation 4 is the one worth reading twice, because it is the shape that occurs in real repos:
# a table whose entry carries something built rather than something declared. It evaluates fine,
# type-checks fine, and renders as a store path -- so nothing complains until someone tries to
# read the fact without building the world.
#
# NEVER exported by this flake, and never composed alongside a real module.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types mkIf;
  cfg = config.purityFixtureImpure.entries;
in
{
  options.purityFixtureImpure.entries = mkOption {
    # `types.attrs` on purpose: a permissive type is exactly how a derivation ends up inside a
    # table that believed itself to be data.
    type = types.attrsOf types.attrs;
    default = { };
    description = "A synthetic table that is NOT pure data. Only lib/purity.nix's self-test uses it.";
  };

  config = mkIf (cfg != { }) {
    systemd.services.purity-fixture-impure-unit.script = "exit 0";
    environment.systemPackages = [ pkgs.hello ];
  };
}
