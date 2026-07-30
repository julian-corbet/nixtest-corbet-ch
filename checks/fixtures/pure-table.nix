# checks/fixtures/pure-table.nix
#
# A synthetic table module that IS pure data, used only to prove `lib/purity.nix` stays silent on
# a compliant module. Deliberately shaped like the real registry-shaped modules in this family
# (an `attrsOf submodule` table, a free-text field nothing branches on, and a self-validating
# assertion) so that "the fixture passes" means something about those modules and not merely
# about an empty option declaration.
#
# The free-text `note` field is the important part of the shape, not decoration: text about an
# INSTANCE has to be a declared field rather than a comment, or it cannot be exported. This
# fixture therefore also proves such a field does not cost purity.
#
# Its namespace (`purityFixture`) exists only here and can never collide with a real option.
{ config, lib, ... }:

let
  inherit (lib) mkOption types mkIf;
  cfg = config.purityFixture.entries;
in
{
  options.purityFixture.entries = mkOption {
    type = types.attrsOf (types.submodule {
      options = {
        value = mkOption {
          type = types.str;
          description = "The fact this entry carries. A plain string, so it survives export.";
        };
        note = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Free text about THIS entry, in the operator's own words. Never branched on by this
            module -- it is here because a comment cannot be exported and this can.
          '';
        };
      };
    });
    default = { };
    description = ''
      A synthetic fact table, for `lib/purity.nix`'s own self-test. Declaring an entry here does
      nothing: no unit, no package, no file.
    '';
  };

  # Validating itself is explicitly NOT an impurity -- a table that checks its own consistency
  # and hands back facts is what "pure data" means. Kept here so the self-test proves that.
  config = mkIf (cfg != { }) {
    assertions = [
      {
        assertion = lib.all (e: e.value != "") (lib.attrValues cfg);
        message = "purityFixture.entries: an entry has an empty value.";
      }
    ];
  };
}
