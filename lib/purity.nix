# lib/purity.nix -- `lib.mkPurityChecks`
#
# The third fixture in this repo, and the only one that tests a CALLER'S OWN MODULE rather than
# assembling a disk: given a module file that claims to be a pure-data table, it mechanically
# proves the claim, and separately proves its own proofs have teeth.
#
# Generalised out of a per-repo check group that several registry-shaped modules in this family
# had each re-derived by hand (nixiam's `posix-purity` group is the surviving original; see
# that repo's `checks/default.nix`). A fixture, never a runner: it returns a list of
# `{ name; ok; detail; }` records and asserts nothing itself, so the caller keeps ownership of
# how a failure is reported -- the same division `mkEfiDisk` and `mkBrokenDisk` already draw.
#
# ── WHY PURITY IS THE LOAD-BEARING PROPERTY, not a style preference ──────────────────────────
#
# Two independent, measured reasons, both about COST rather than taste:
#
#   1. The NixOS module system has no partial evaluation. Touching `config.<anything>` forces
#      the entire fixpoint, every module merged. So a consumer that reads ONE fact out of a
#      module pays for that module's whole evaluation -- and if the module is impure enough to
#      need a system around it, for the system's evaluation too. Measured on the hosts this
#      family was built for: a full host evaluation is ~95 s; importing a plain-data .nix file
#      is ~0.021 s. Three orders of magnitude, for the same fact.
#
#   2. A module that is pure data is exactly a module whose facts can be SERIALISED -- dumped to
#      JSON, read by a tool that has no Nix at all, rendered by something that is not a build.
#      A fact welded into a mechanism (a string inside a systemd unit's `script`, a version
#      inside a bash heredoc) cannot be exported without evaluating and then TEXT-PARSING a
#      derivation. `factPaths` below turns that from an aspiration into a check.
#
# ── The definition of "pure" this enforces, stated precisely ─────────────────────────────────
#
# A module is PURE DATA for this fixture's purposes iff ALL THREE hold:
#
#   1. Its own top-level module function never binds a `pkgs` formal argument -- checked via
#      `builtins.functionArgs`, not a text search, because a module can reference something
#      called `pkgs` under a different bound name or smuggle it in through `...`, but it cannot
#      LEGALLY use it as `pkgs` inside its own body without that name appearing as a formal
#      argument first.
#   2. Composing it ALONE (plus a bare, non-bootable stub system) against a realistic,
#      non-default USE of its own options produces IDENTICAL values on every watched surface
#      (by default: `systemd.services`, `environment.systemPackages`; plus any `extraSurfaces`
#      the caller supplies) to the same bare stub system with the module absent entirely.
#      THIS IS THE LOAD-BEARING HALF, and the one every watched surface gets regardless of
#      source: it is not enough that the module's own text never writes a watched option path
#      directly (see 3) -- an INDIRECT path, some other option that happens to expand into a
#      systemd unit or a package, dodges a text scan but cannot dodge this, because it diffs
#      what the module system actually PRODUCES.
#   3. For the two BASE surfaces only (`systemd.services`, `environment.systemPackages`): its
#      source text, comments stripped, never contains the literal option-path string. A cheap,
#      fast-failing companion to (2) that gives a violator's own diff a readable reason without
#      waiting for a full NixOS eval -- deliberately NOT extended to `extraSurfaces`, see below.
#
# Declaring `options` and `config.assertions` is explicitly NOT a violation of any of the three.
# A table that only ever validates itself and hands back facts is exactly what "pure data" means
# here -- e.g. nixstorage's `modules/disks.nix` branches on `config.assertions` to refuse a
# duplicate device path and stays pure by this definition.
#
# ── What this does NOT prove, stated as honestly as what it does ─────────────────────────────
#
# `systemd.services` and `environment.systemPackages` are the two surfaces the original check
# group named, and the two `baseSurfaces` below watches unconditionally -- they are not the only
# way a module could stop being pure data (a stray `users.users.*` entry with no `pkgs` involved
# at all would dodge both). `extraSurfaces` exists for exactly that gap: a caller whose own
# module header promises something more specific hands this function one more
# `{ path; value; decoy; }` record and gets the load-bearing eval-diff proof (2) and its
# meta-test for that surface too -- but deliberately NOT the text scan (3): a table's own option
# `description` is exactly the place a caller legitimately needs to name a guarded option in
# PROSE ("this is `networking.hostName` on NixOS, or the equivalent on..."), and a literal scan
# cannot tell that string apart from an actual write.
#
# That was not a hypothetical worry. It is what happened the first time an
# `extraSurfaces = [ networking.hostName ]` was tried against a real registry: a correct,
# non-violating `description` string tripped `source-never-mentions-networking.hostName` before
# the text scan was scoped to base surfaces only. A module that adds some fourth,
# still-unwatched NixOS-only primitive is this fixture's remaining honest gap -- watch it
# explicitly via `extraSurfaces` the day it becomes a real risk, rather than claiming a coverage
# this mechanism does not have.
#
# ── The meta-tests, and why they exist ──────────────────────────────────────────────────────
#
# A comparison that has never been shown capable of failing is not a proof, it is an assumption
# wearing a proof's clothes. `decoyModule` below DOES bind `pkgs`, DOES add a systemd unit and a
# package, and DOES touch every `extraSurfaces` entry the caller supplies -- composed only
# against the bare stub, never alongside the real module under test -- so every check gets a
# companion meta-test proving it actually notices a real violation, not merely that the module
# under test happens not to have one today. `factPaths` gets the same treatment: a decoy value
# carrying a real derivation proves the serialisation check can fail.
#
# ── Arguments ───────────────────────────────────────────────────────────────────────────────
#
#   lib, nixpkgs, system  -- from the caller's own evaluation.
#   label                 -- prefix for every check name, conventionally the namespace under
#                            test (e.g. "disks"), so a failure report says which table broke.
#   modulePath            -- path to the single module file under test.
#   bareStubs             -- the minimum module set that makes `eval-config.nix` evaluate
#                            without a real machine (fileSystems, boot loader, stateVersion...).
#                            The SAME value must be used for the caller's other eval fixtures,
#                            or the "bare" baseline drifts away from what the caller tests.
#   populatedConfig       -- a realistic, NON-DEFAULT use of the module's own options. Passing
#                            `{ }` here would make check (2) vacuous: a module that declares
#                            options nobody set cannot change any surface.
#   extraSurfaces         -- optional extra `{ path; value; decoy; }` records; see above.
#   factPaths             -- optional list of dotted option paths (e.g. "nixstorage.disks")
#                            whose evaluated value must be plain serialisable data. Proven by
#                            JSON round-trip equality, which is stricter than it looks: a
#                            derivation serialises to its store-path STRING and so fails to
#                            round-trip back to an attrset, a function makes `toJSON` throw, and
#                            a path serialises to a string while also dragging the file into the
#                            store. Only strings, numbers, bools, null, and lists/attrsets of
#                            those survive -- which is precisely the definition of exportable.
{ lib
, nixpkgs
, system
, label
, modulePath
, bareStubs
, populatedConfig
, extraSurfaces ? [ ]
, factPaths ? [ ]
}:

let
  check = name: ok: detail: { inherit name ok detail; };

  isCommentLine = line: builtins.match "[ \t]*#.*" line != null;
  stripComments = src:
    lib.concatStringsSep "\n"
      (lib.filter (l: !(isCommentLine l)) (lib.splitString "\n" src));

  moduleSrc = stripComments (builtins.readFile modulePath);

  evalNixosModules = modules:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system modules;
    }).config;

  sorted = lib.sort (a: b: a < b);

  # The two surfaces the original check group named by name -- see this file's header for why
  # these two are the unconditional default rather than an exhaustive list.
  baseSurfaces = [
    {
      path = "systemd.services";
      value = cfg: sorted (lib.attrNames cfg.systemd.services);
    }
    {
      path = "environment.systemPackages";
      value = cfg: sorted (map (p: p.name) cfg.environment.systemPackages);
    }
  ];

  allSurfaces = baseSurfaces ++ extraSurfaces;

  cfg-bare = evalNixosModules [ bareStubs ];
  cfg-module-alone = evalNixosModules [ modulePath bareStubs populatedConfig ];

  # A deliberately broken stand-in, used ONLY to prove the checks below have teeth -- never
  # composed alongside the real module under test, and never exported by any flake in this
  # family. Its own namespace (`purityCheckDecoy`) can never collide with a real option.
  decoyModule = { config, lib, pkgs, ... }: {
    options.purityCheckDecoy.enable =
      lib.mkEnableOption "decoy, for this fixture's own meta-tests -- never a real module";
    config = lib.mkIf config.purityCheckDecoy.enable (lib.mkMerge (
      [
        { systemd.services.purity-check-decoy-unit.script = "exit 0"; }
        { environment.systemPackages = [ pkgs.hello ]; }
      ]
      ++ map (s: s.decoy) extraSurfaces
    ));
  };

  cfg-decoy-alone = evalNixosModules [ bareStubs decoyModule { purityCheckDecoy.enable = true; } ];

  # The load-bearing pair, run for EVERY surface (base and extra alike): the eval-diff proof
  # itself, and the meta-test proving that proof has teeth. Neither reads the module's source
  # text, so neither can be fooled by a legitimate PROSE mention of the watched option path
  # inside the module's own `description` strings -- unlike the text scan below.
  evalDiffChecks = s: [
    (check "${label}-purity/alone-never-changes-${s.path}"
      (s.value cfg-module-alone == s.value cfg-bare)
      "composing this module alone (with a realistic, non-default use of its own options) changed ${s.path} vs. the identical system without it -- got: ${builtins.toJSON (s.value cfg-module-alone)}, expected: ${builtins.toJSON (s.value cfg-bare)}")

    (check "${label}-purity/mechanism-catches-a-${s.path}-change (meta-test)"
      (s.value cfg-decoy-alone != s.value cfg-bare)
      "a decoy module that DOES change ${s.path} was not caught by this comparison -- the comparison itself is what's broken, not the module under test")
  ];

  # The cheap, fast-failing companion -- BASE SURFACES ONLY. Deliberately not run against
  # `extraSurfaces`: a caller's own module is free to (and, for a registry, often should)
  # mention a guarded option's dotted path in an option's own `description` prose, which is a
  # real Nix string in the module's CODE, not a `#` comment `stripComments` would remove -- a
  # literal scan cannot tell that apart from an actual write. See the header for the real false
  # positive this scoping exists to avoid.
  sourceScanChecks = s: [
    (check "${label}-purity/source-never-mentions-${s.path}"
      (!(lib.hasInfix s.path moduleSrc))
      "${modulePath}'s source text now contains the literal string \"${s.path}\"")
  ];

  # ── Plain-data facts: what the table publishes must be readable without building anything ──
  #
  # ⚠ WHY THIS IS A STRUCTURAL SCAN AND NOT `fromJSON (toJSON v) == v`. The round-trip form was
  # tried first and is unusable, measured here 2026-07-30: `toJSON` on a value containing a
  # derivation returns a string CARRYING STORE CONTEXT, `fromJSON` then refuses it outright
  # ("the string '...' is not allowed to refer to a store path"), and `builtins.tryEval` does
  # NOT catch that -- tryEval only intercepts `throw` and `assert`, so this aborted the whole
  # evaluation instead of failing as a check. A direct scan cannot abort, and as a bonus it
  # reports WHICH attribute is impure instead of only that something is.
  #
  # Returns the offending paths, so an empty list means plain data.
  impureFactPaths = prefix: v:
    if builtins.isAttrs v then
      (if v ? outPath || v ? drvPath || (v.type or null) == "derivation"
      then [ "${prefix} (a derivation -- reading this fact forces a build)" ]
      else lib.concatLists (lib.mapAttrsToList (n: sub: impureFactPaths "${prefix}.${n}" sub) v))
    else if builtins.isList v then
      lib.concatLists (lib.imap0 (i: sub: impureFactPaths "${prefix}[${toString i}]" sub) v)
    else if builtins.isFunction v then [ "${prefix} (a function)" ]
    else if builtins.isPath v then [ "${prefix} (a path -- copies the file into the store)" ]
    else if builtins.isString v && builtins.hasContext v then
      [ "${prefix} (a string carrying store context)" ]
    else [ ];

  factChecks = path:
    let
      v = lib.getAttrFromPath (lib.splitString "." path) cfg-module-alone;
      bad = impureFactPaths path v;
    in
    [
      (check "${label}-purity/${path}-is-plain-data"
        (bad == [ ])
        "`${path}` is not plain data, so this fact cannot be read without dragging a build in behind it: ${lib.concatStringsSep ", " bad}. Facts must be strings (without store context), numbers, bools, null, or lists/attrsets of those.")
    ];

  # One decoy covers every fact path -- the mechanism is identical for all of them, so a single
  # proof that a derivation-carrying value is rejected proves the scan has teeth.
  factMetaChecks =
    lib.optional (factPaths != [ ])
      (check "${label}-purity/mechanism-catches-a-non-plain-fact (meta-test)"
        (impureFactPaths "decoy" { welded = (import nixpkgs { inherit system; }).hello; } != [ ])
        "a decoy fact value carrying a real derivation was accepted by the plain-data scan -- the scan itself is broken, not the table under test");
in
[
  (check "${label}-purity/no-pkgs-argument"
    (!(lib.functionArgs (import modulePath) ? pkgs))
    "${modulePath}'s own module function now binds a `pkgs` argument -- pure-data tables in this family never take one")
]
++ lib.concatMap sourceScanChecks baseSurfaces
++ lib.concatMap evalDiffChecks allSurfaces
++ lib.concatMap factChecks factPaths
++ factMetaChecks
++ [
  (check "${label}-purity/functionArgs-mechanism-catches-a-pkgs-argument (meta-test)"
    (lib.functionArgs decoyModule ? pkgs)
    "the decoy module (which binds `pkgs` itself) was not detected by functionArgs -- the mechanism itself is broken")
]
