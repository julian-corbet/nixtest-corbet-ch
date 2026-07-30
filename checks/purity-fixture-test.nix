# checks/purity-fixture-test.nix
#
# `lib/purity.nix`'s own self-test, in both directions -- the discipline this repo applies to every
# fixture it ships: a harness is only trustworthy once it has been shown to fail.
#
#   POSITIVE  checks/fixtures/pure-table.nix   is a real pure-data table (attrsOf submodule, a
#             free-text field nothing branches on, a self-validating assertion) and EVERY check
#             mkPurityChecks emits must pass against it.
#   NEGATIVE  checks/fixtures/impure-table.nix violates all four properties, and each specific
#             check must fire -- named individually, so a check that silently stops working is
#             caught rather than absorbed into a vague "something failed".
#
# The meta-tests must pass in BOTH runs: they test the mechanism, not the module under test, so a
# meta-test that fails on the violator would mean the comparison machinery is broken.
#
# ⚠ COST NOTE. Each mkPurityChecks call performs three full `eval-config.nix` evaluations (bare,
# module-alone, decoy-alone), and this file makes two calls -- six NixOS evaluations. That is why
# this is a separate check rather than folded into eval-tests.nix, which is meant to stay
# instantaneous. It builds nothing and boots nothing.
{ pkgs, lib, nixpkgs, mkPurityChecks, system }:

let
  check = name: ok: detail: { inherit name ok detail; };

  # The minimum that makes eval-config.nix evaluate without a real machine. Deliberately shared by
  # both runs below so the "bare" baseline is identical on each side of the comparison.
  bareStubs = {
    boot.loader.grub.enable = false;
    fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
    system.stateVersion = "25.05";
  };

  # ── POSITIVE: the compliant table ────────────────────────────────────────────────────────────
  # `populatedConfig` uses the module for real -- two entries, one carrying the free-text field.
  # Passing `{ }` here would make the eval-diff check vacuous: a module whose options nobody set
  # cannot change any surface, so it would "pass" without proving anything.
  pureResults = mkPurityChecks {
    inherit lib nixpkgs system bareStubs;
    label = "fixture-pure";
    modulePath = ./fixtures/pure-table.nix;
    populatedConfig = {
      purityFixture.entries = {
        first = { value = "a"; note = "why this entry is special, in prose that exports"; };
        second = { value = "b"; };
      };
    };
    factPaths = [ "purityFixture.entries" ];
  };

  pureFailures = lib.filter (r: !r.ok) pureResults;

  # ── NEGATIVE: the violator ───────────────────────────────────────────────────────────────────
  # A module FUNCTION rather than an attrset, because the decoy fact has to be a real derivation
  # and therefore needs `pkgs` from the evaluation itself.
  impureResults = mkPurityChecks {
    inherit lib nixpkgs system bareStubs;
    label = "fixture-impure";
    modulePath = ./fixtures/impure-table.nix;
    populatedConfig = { pkgs, ... }: {
      purityFixtureImpure.entries.welded = { built = pkgs.hello; };
    };
    factPaths = [ "purityFixtureImpure.entries" ];
  };

  impureByName = lib.listToAttrs (map (r: lib.nameValuePair r.name r) impureResults);

  # Every violation the decoy table commits, named explicitly. A check that vanishes (renamed,
  # accidentally dropped) fails here as a MISSING name rather than passing by absence -- which is
  # the failure mode a bare `any (r: !r.ok)` would hide.
  expectedToFire = [
    "fixture-impure-purity/no-pkgs-argument"
    "fixture-impure-purity/source-never-mentions-systemd.services"
    "fixture-impure-purity/source-never-mentions-environment.systemPackages"
    "fixture-impure-purity/alone-never-changes-systemd.services"
    "fixture-impure-purity/alone-never-changes-environment.systemPackages"
    "fixture-impure-purity/purityFixtureImpure.entries-is-plain-data"
  ];

  firedChecks = map
    (name:
      check "purity-selftest/violator-trips-${name}"
        (impureByName ? ${name} && !impureByName.${name}.ok)
        (if !(impureByName ? ${name})
        then "no check named `${name}` was emitted at all -- it was renamed or dropped, so nothing is testing that property any more"
        else "`${name}` PASSED against checks/fixtures/impure-table.nix, which violates that very property on purpose"))
    expectedToFire;

  # The meta-tests prove the machinery, so they must hold on both sides. On the violator run in
  # particular: if a meta-test fails there, the comparison itself is broken and every other verdict
  # in this file is worthless.
  metaTests = lib.filter (r: lib.hasInfix "(meta-test)" r.name) (pureResults ++ impureResults);

  results = [
    (check "purity-selftest/compliant-table-passes-every-check"
      (pureFailures == [ ])
      "checks/fixtures/pure-table.nix is a genuine pure-data table but mkPurityChecks reported failures: ${lib.concatMapStringsSep "; " (r: "${r.name} -- ${r.detail}") pureFailures}")

    (check "purity-selftest/compliant-run-emitted-checks-at-all"
      (lib.length pureResults >= 8)
      "expected at least 8 checks from the compliant run (1 pkgs + 2 source scans + 2x2 eval-diff pairs + 1 factPath + its meta-test + the functionArgs meta-test); got ${toString (lib.length pureResults)} -- a silently shrinking check set means coverage was lost, not that the module improved")
  ]
  ++ firedChecks
  ++ map
    (r: check "purity-selftest/meta-test-holds-${r.name}" r.ok
      "a meta-test failed (${r.detail}) -- the purity mechanism itself is broken, so no other verdict in this file can be trusted")
    metaTests;

  failed = lib.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
if failed != [ ]
then
  throw ''
    nixtest purity-fixture-test FAILED (${toString (lib.length failed)}/${toString (lib.length results)}):
    ${report}
  ''
else
  pkgs.runCommand "nixtest-purity-fixture-test"
    { passthru.checkCount = lib.length results; }
    ''
      echo "${toString (lib.length results)} purity self-test assertions passed" > $out
    ''
