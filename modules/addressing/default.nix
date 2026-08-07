# nixk3s.addressing — the band model: which slots a declaring repository's apps
# are allowed to occupy, and a guard that refuses everything outside them.
#
# THE MODEL, in three terms:
#
#   SLOT     One number, held by one addressable workload. It is NOT an address.
#            It is an identity that the layers underneath map INTO addresses,
#            and a fleet normally maps the same number into more than one space
#            at once — an in-cluster address in one range, an overlay peer
#            address in another, the DNS names derived from those. That
#            correspondence is the whole value of the model (one registry drives
#            every plane from a single number) and equally the whole hazard: a
#            slot that moves moves every one of those planes at the same
#            instant.
#
#   BAND     A contiguous run of slots (sixteen by default) reserved for one
#            category of thing.
#
#   BINDING  A declaring module set — in practice a repository — binds exactly
#            ONE band, and every app it declares takes its slot from that band.
#
# BINDING IS NOT OPTIONAL. A repository that binds a band is one you can deploy
# into the cluster while knowing where its services will land; a repository that
# binds none has to be reasoned about one app at a time, forever. So while this
# module is enabled, an app whose origin binds no band fails eval. Where the
# right category is genuinely not obvious, bind the fallback band
# (`fallbackBand`) DELIBERATELY — a decision somebody can find later. That is
# also why there is no implicit fallback: a silent default is exactly how
# everything ends up in the grab-bag band without anyone ever choosing it.
#
# WHAT IS PUBLIC HERE AND WHAT IS NOT. The mechanism is public; the layout is
# not. This module declares the terms — bands exist, they have a base and a
# size, origins bind them, apps take slots inside them — and knows no band, no
# base, no slot and no binding of its own. Every one of those is a value the
# consumer supplies, exactly as `nixk3s.apps` takes its namespaces and node
# paths. Which category owns which range, and which repository owns which
# category, is the shape of somebody's fleet and stays in the repository that
# owns the fleet.
#
# A GUARD, NOT AN ALLOCATOR — the load-bearing decision in this file. Nothing
# here assigns a slot and nothing here moves one. Existing slots are LIVE
# IDENTITIES: an allocator that tidied a band would rewrite an in-cluster
# address and an overlay peer address in one commit, and the app would come back
# somewhere other than where every consumer of it expects. So the module does
# exactly two things:
#
#   1. it REFUSES, at eval, a slot outside the band its origin bound, naming the
#      app, the slot, the band the slot landed in and the band it should be in;
#   2. it REPORTS the next free slot in a band (`report.<band>.nextFree`), so
#      the human adding an app is told the number instead of guessing it.
#
# The report fills BOTTOM-UP — `nextFree` is always the lowest free slot in the
# band — because that is the convention these bands are allocated by. It stays
# advice rather than an assignment for a second reason beyond safety: a band is
# ordered internally too (an operator conventionally sits just below the
# instances it operates), and only the person adding the app knows which of
# those two things they are adding.
#
# CAPACITY IS FINITE AND THE ERROR SAYS SO. A band holds `size` slots and
# nothing in this module can extend it. A band that fills up therefore fails
# eval with "this band is full" the moment another addressable app is bound to
# it — instead of leaving somebody to pick a plausible-looking number that
# belongs to a different category, which is a collision in every plane the slot
# feeds at once. `warnFreeAtOrBelow` says so earlier, while there is still room
# to plan.
{ lib, config, options, ... }:
let
  cfg = config.nixk3s.addressing;

  # The app grammar is a SIBLING, not a dependency: this module adds two terms
  # to `nixk3s.apps` and governs them, but the option is owned (and defaulted)
  # by the apps module. Reading `config.nixk3s.apps` when nothing has defined it
  # and no default exists would throw, so the definedness is checked first —
  # which is also correct when the apps module IS present and simply has no apps.
  apps = lib.optionalAttrs options.nixk3s.apps.isDefined config.nixk3s.apps;
  enabledApps = lib.filterAttrs (_: app: app.enable or true) apps;

  ## ---------------------------------------------------------------------
  ## Bands
  ## ---------------------------------------------------------------------

  bandNames = lib.attrNames cfg.bands;
  lastSlotOf = band: cfg.bands.${band}.base + cfg.bands.${band}.size - 1;
  slotsOf = band: lib.range cfg.bands.${band}.base (lastSlotOf band);
  inBand = band: slot: slot >= cfg.bands.${band}.base && slot <= lastSlotOf band;

  # Which band a NUMBER falls in, independent of who claimed it — the honest
  # answer to "where did this slot actually land", which is what an out-of-band
  # error has to be able to say. `null` when the number is outside every band.
  bandContaining = slot: lib.findFirst (band: inBand band slot) null bandNames;

  # A band in a message: its name, plus the description it was declared with.
  # A band name is short enough to be ambiguous a year later, and the eval
  # errors are the place that ambiguity actually costs someone time.
  showBand = band:
    "`${band}`"
    + lib.optionalString
      (cfg.bands ? ${band} && cfg.bands.${band}.description != "")
      " (${cfg.bands.${band}.description})"
    + lib.optionalString (cfg.bands ? ${band})
      " = slots ${toString cfg.bands.${band}.base}..${toString (lastSlotOf band)}";

  ## ---------------------------------------------------------------------
  ## Occupancy
  ##
  ## Occupancy is counted by POSITION, never by binding: two apps on one number
  ## collide in every address space that number feeds, whichever repository
  ## declared them, and an app whose slot is out of its own band still occupies
  ## the band it landed in until somebody moves it deliberately.
  ## ---------------------------------------------------------------------

  claims = lib.mapAttrsToList (name: app: { inherit name; inherit (app) slot; })
    (lib.filterAttrs (_: app: app.slot != null) enabledApps);

  claimantsOf = slot: map (c: c.name) (lib.filter (c: c.slot == slot) claims);

  duplicatedSlots =
    lib.filter (slot: lib.length (claimantsOf slot) > 1)
      (lib.unique (map (c: c.slot) claims));

  reportOf = band:
    let
      taken = lib.filter (c: inBand band c.slot) claims;
      takenSlots = lib.unique (map (c: c.slot) taken);
      free = lib.filter (slot: !(lib.elem slot takenSlots)) (slotsOf band);
    in
    {
      inherit (cfg.bands.${band}) base size;
      last = lastSlotOf band;
      taken = lib.listToAttrs (map (c: lib.nameValuePair (toString c.slot) c.name) taken);
      inherit free;
      # Lowest first: the bands are filled bottom-up, so the lowest free slot is
      # the one the convention asks for.
      nextFree = if free == [ ] then null else lib.head free;
      origins = lib.attrNames (lib.filterAttrs (_: b: b == band) cfg.bindings);
    };

  ## ---------------------------------------------------------------------
  ## Per-app resolution
  ## ---------------------------------------------------------------------

  # The band an app's ORIGIN bound, or null when the app names no origin, the
  # origin binds nothing, or the binding names a band nobody declared. Each of
  # those has its own assertion below, so this only has to stay total.
  boundBandOf = app:
    if app.origin == null then null
    else if !(cfg.bindings ? ${app.origin}) then null
    else if !(cfg.bands ? ${cfg.bindings.${app.origin}}) then null
    else cfg.bindings.${app.origin};

  # An app that renders a Service is an app with an in-cluster address, which is
  # what a slot names. A portless workload (a worker, a cron-shaped process) has
  # nothing to address and is not asked for one.
  #
  # `or { }` keeps this total when the apps module is absent and `ports` is
  # therefore not a term at all.
  addressable = app: (app.ports or { }) != { };

  # Never interpolate a nullable straight into a message: an assertion's message
  # is a typed string, so it is forced whether or not the assertion holds — a
  # message that only works when its own assertion fails takes the whole
  # evaluation down with a `null` coercion instead of reporting anything.
  showOrigin = app: if app.origin == null then "(unset)" else "`${app.origin}`";
  originName = app: if app.origin == null then "<origin>" else app.origin;
  showSlot = app: if app.slot == null then "(none)" else toString app.slot;
  showBound = app:
    let band = boundBandOf app; in
    if band == null then "(no band)" else showBand band;
  showLanded = app:
    if app.slot == null then "(no slot)"
    else
      let band = bandContaining app.slot; in
      if band == null then "no declared band at all" else showBand band;

  nextFreeIn = band:
    if band == null || !(cfg.report ? ${band}) then null else cfg.report.${band}.nextFree;

  takenIn = band:
    if band == null || !(cfg.report ? ${band}) then [ ]
    else lib.attrValues cfg.report.${band}.taken;

  sizeOf = band: if band == null || !(cfg.bands ? ${band}) then 0 else cfg.bands.${band}.size;

  # What to tell someone whose app has to end up somewhere in `band`: the number
  # to use, or the fact that there is no number left to give them.
  showRoom = band:
    let next = nextFreeIn band; in
    if band == null || !(cfg.bands ? ${band}) then "there is no band to place it in"
    else if next == null then
      "band `${band}` is full: all ${toString (sizeOf band)} of its slots are taken"
    else "the next free slot in band `${band}` is ${toString next}";

  ## ---------------------------------------------------------------------
  ## Assertions
  ## ---------------------------------------------------------------------

  bandAssertions =
    lib.mapAttrsToList
      (origin: band: {
        assertion = cfg.bands ? ${band};
        message =
          "origin `${origin}` binds band `${band}`, which `nixk3s.addressing.bands` does not declare. "
          + "A binding to a band that does not exist governs nothing: every slot in that origin would "
          + "pass unchecked. Declare the band, or bind one of "
          + (if bandNames == [ ] then "the bands you declare" else lib.concatMapStringsSep ", " (b: "`${b}`") bandNames)
          + ".";
      })
      cfg.bindings
    ++ [
      {
        assertion = cfg.fallbackBand == null || cfg.bands ? ${cfg.fallbackBand};
        message =
          "`nixk3s.addressing.fallbackBand` names band "
          + "`${toString cfg.fallbackBand}`, which is not declared in `nixk3s.addressing.bands`. "
          + "The fallback is what an origin binds when the right category is not obvious; a fallback "
          + "that does not exist turns that into an eval error at the worst possible moment.";
      }
    ]
    ++ map
      (pair: {
        assertion = false;
        message =
          "bands ${showBand pair.a} and ${showBand pair.b} overlap. One slot would then belong to two "
          + "categories at once, and which one a guard reports would depend on attribute order — so "
          + "the overlap is refused instead. Bands are contiguous, non-overlapping runs.";
      })
      overlappingBands
    ++ map
      (slot: {
        assertion = false;
        message =
          "slot ${toString slot} is claimed by more than one app: "
          + lib.concatMapStringsSep ", " (n: "`${n}`") (claimantsOf slot)
          + ". A slot is ONE identity in every address space the fleet maps it into, so two claimants "
          + "is a collision in all of them at once. Give one of them another slot — "
          + showRoom (bandContaining slot) + ".";
      })
      duplicatedSlots;

  overlappingBands =
    let
      names = bandNames;
      count = lib.length names;
      overlaps = a: b:
        cfg.bands.${a}.base <= lastSlotOf b && cfg.bands.${b}.base <= lastSlotOf a;
    in
    lib.concatMap
      (i: lib.concatMap
        (j:
          let a = lib.elemAt names i; b = lib.elemAt names j; in
          lib.optional (overlaps a b) { inherit a b; })
        (lib.range (i + 1) (count - 1)))
      (lib.range 0 (count - 1));

  appAssertions = name: app:
    let
      bound = boundBandOf app;
    in
    [
      {
        assertion = app.origin != null;
        message =
          "app `${name}` names no `origin`, so nothing says which repository declared it and nothing "
          + "says which band its slot may come from. Every declaring module set binds a band — set "
          + "`nixk3s.apps.${name}.origin` to the name of the one that declares this app.";
      }
      {
        assertion = app.origin == null || cfg.bindings ? ${app.origin};
        message =
          "app `${name}` comes from origin ${showOrigin app}, which binds no band. Every origin must "
          + "bind one: that is what makes a repository deployable into this cluster without reasoning "
          + "about its apps one at a time. Set `nixk3s.addressing.bindings.${originName app}`"
          + lib.optionalString (cfg.fallbackBand != null)
            ", and when the right category is genuinely not obvious bind the fallback band `${toString cfg.fallbackBand}` deliberately rather than leaving this unset"
          + ".";
      }
      {
        # THE GUARD. Not a warning, and not a fixup: the slot is already an
        # identity in several address spaces, so the only safe thing to do with
        # a wrong one is refuse it and let a human move it knowingly.
        assertion = app.slot == null || bound == null || inBand bound app.slot;
        message =
          "app `${name}` claims slot ${showSlot app}, which is in ${showLanded app}, but its origin "
          + "${showOrigin app} binds ${showBound app}. A slot is one identity in every address space "
          + "the fleet maps it into, so nothing here will move it for you — moving it changes all of "
          + "them at once. Either give the app a slot inside its own band (${showRoom bound}), or "
          + "rebind its origin.";
      }
      {
        # Capacity, said clearly and at eval, rather than left to become a
        # collision or a number borrowed from the neighbouring category.
        assertion =
          !(addressable app) || app.slot != null || bound == null
          || nextFreeIn bound != null;
        message =
          "app `${name}` renders a Service and so needs a slot, but its origin ${showOrigin app} binds "
          + "${showBound app}, which is FULL — all ${toString (sizeOf bound)} slots are taken by "
          + lib.concatMapStringsSep ", " (n: "`${n}`") (takenIn bound)
          + ". A band cannot be extended. Bind this origin to a band with room, or free a slot "
          + "deliberately — reassigning one that is in use changes a live address in every plane that "
          + "slot feeds.";
      }
    ];

  ## ---------------------------------------------------------------------
  ## Warnings
  ## ---------------------------------------------------------------------

  capacityWarnings = map
    (band:
      let free = lib.length cfg.report.${band}.free; in
      {
        # `free < size` keeps an EMPTY narrow band quiet: a band nobody has
        # taken a slot in is not filling up, however few slots it holds.
        when = cfg.warnFreeAtOrBelow > 0 && free > 0
          && free < cfg.bands.${band}.size && free <= cfg.warnFreeAtOrBelow;
        message =
          "band ${showBand band} has ${toString free} free slot(s) left of "
          + "${toString cfg.bands.${band}.size}. A band cannot be extended, so the next app past that "
          + "is an eval error, not a squeeze: "
          + (if cfg.report.${band}.origins == [ ] then "no origin binds it yet"
          else "origins " + lib.concatMapStringsSep ", " (o: "`${o}`") cfg.report.${band}.origins)
          + ".";
      })
    bandNames;

  appWarnings = name: app:
    let
      bound = boundBandOf app;
      next = nextFreeIn bound;
    in
    [
      {
        when = addressable app && app.slot == null && next != null;
        message =
          "app `${name}` renders a Service but claims no slot, so its in-cluster address is whatever "
          + "the cluster hands out and it has no identity in any other plane. Here "
          + showRoom bound
          + " — set `nixk3s.apps.${name}.slot` to it, or to another free slot in that band if this "
          + "app belongs elsewhere in the band's own order.";
      }
    ];
in
{
  # The two terms this model adds to the app grammar. They are DECLARED here,
  # beside the thing that governs them, rather than in the grammar that merely
  # carries them: `nixk3s.apps` is an attrset of submodules, so a second
  # declaration of the option merges its submodule into the first one and the
  # app keeps a single, flat vocabulary. No default, description or example
  # appears here — those belong to the declaration that owns the option.
  options.nixk3s.apps = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = {
        origin = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            WHICH DECLARING MODULE SET this app comes from — in practice the
            repository whose modules declare it. Not a Kubernetes namespace and
            not a cluster: it is the identity that binds a band, and every app
            declared by the same repository names the same one.

            A repository naming ITSELF is not a fleet fact, so a public module
            set may set this on its own apps; which band that origin binds is a
            fleet fact and lives in `nixk3s.addressing.bindings`, in whatever
            repository owns the fleet.

            One line per app is one line too many when a repository declares a
            dozen. Stamp them all at once instead — definitions of an attrset of
            submodules merge, so a module set can add

            ```nix
            nixk3s.apps = lib.genAttrs [ "one" "two" "three" ] (_: {
              origin = "example-repo";
            });
            ```

            beside its declarations and leave them otherwise untouched.
          '';
        };

        slot = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.unsigned;
          default = null;
          description = ''
            THE SLOT this app holds: one number, inside the band its `origin`
            binds. Not an address — the layers underneath map it into however
            many address spaces the fleet keeps, which is exactly why it must
            not move: they all move with it.

            The VALUE is a fleet fact and belongs to the private consumer that
            passes it in, exactly like `state.<name>.hostPath`. A public
            declaration takes it as a parameter and never writes one down.

            Nothing is rendered from it here. This module governs the number;
            what an address looks like is the private layer's business, and it
            reads this option to set one (a pinned ClusterIP is a typed merge
            onto the Service this grammar already renders).

            `null` means unaddressed. That is right for a portless workload; an
            app that renders a Service and leaves this null gets a warning
            naming the next free slot in its band, and is refused outright once
            that band is full.
          '';
        };
      };
    }));
  };

  options.nixk3s.addressing = {
    enable = lib.mkEnableOption
      "the band model — an origin binds a band, its apps take slots inside it, and a slot outside it fails eval";

    bands = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          base = lib.mkOption {
            type = lib.types.ints.unsigned;
            description = ''
              FIRST slot in this band. Where a category starts in the number
              space is the shape of somebody's fleet, so it is supplied here by
              the consumer and guessed nowhere.
            '';
          };

          size = lib.mkOption {
            type = lib.types.ints.positive;
            default = 16;
            description = ''
              How many slots the band holds, counting `base`. Sixteen by
              default, because a sixteen-wide block is one nibble of a
              byte-sized number space and that is the usual way such a space is
              cut into categories; a model cut some other way says so here.

              It is a CEILING, not a target. Nothing can extend a band, so this
              is the number of things the category will ever address — and the
              number the "band is full" eval error counts against.
            '';
          };

          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = ''
              What this category is FOR, in a few words. Optional and worth
              writing: a band name is usually short enough to be ambiguous a
              year later, and this string is what the eval errors and the report
              have to explain themselves with.
            '';
          };
        };
      });
      default = { };
      description = ''
        The bands, keyed by name. EMPTY by default and empty in this repository
        forever: which categories exist, and which run of the number space each
        one owns, is fleet layout. The mechanism is public, the map is not.

        Bands must not overlap — one slot belonging to two categories makes
        every guard here depend on attribute order — and eval fails when two do.
      '';
      example = lib.literalExpression ''
        {
          example-alpha = { base = 32; description = "one category"; };
          example-beta = { base = 48; size = 8; description = "another, half as wide"; };
        }
      '';
    };

    bindings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        THE BINDING: which band each declaring origin owns, as
        `<origin> = "<band>"`. One band per origin; several origins may share a
        band.

        EVERY ORIGIN MUST APPEAR HERE. An app whose origin is missing fails eval
        while this module is enabled, because an unbound repository is one whose
        apps have to be placed by hand, one at a time, forever — and the point
        of binding is that a repository can be deployed into the cluster knowing
        where its services land.

        Where the right category is genuinely not obvious, bind the band
        `fallbackBand` names — DELIBERATELY, as a written decision. There is no
        implicit fallback here on purpose: an automatic one is how everything
        ends up in the grab-bag band without anybody ever choosing it.

        The map itself is fleet layout — which repository owns which category —
        so it is EMPTY here and filled in privately, like every other value this
        repository declares and refuses to supply.
      '';
      example = lib.literalExpression ''{ example-repo = "example-alpha"; }'';
    };

    fallbackBand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The band an origin binds when no category obviously fits — the
        grab-bag, named once so that "in doubt, take this one" is an answer
        somebody can look up instead of a habit.

        It is NEVER applied automatically. Nothing defaults to it, nothing falls
        back to it; an unbound origin fails eval and this option only makes the
        error able to say what to do about it. That is the entire difference
        between a documented fallback and a silent default: the first leaves a
        decision in the tree, the second leaves a mess in one band.

        `null` by default, because which band is the grab-bag is — like every
        other band — fleet layout.
      '';
    };

    warnFreeAtOrBelow = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 2;
      description = ''
        Warn about a band once it has this many free slots left, or fewer. A
        band cannot be extended, so the app after the last one is an eval error
        rather than a squeeze; this is the notice that arrives while there is
        still room to plan for it. `0` turns the warning off.
      '';
    };

    report = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          base = lib.mkOption {
            type = lib.types.ints.unsigned;
            description = "First slot in the band.";
          };
          last = lib.mkOption {
            type = lib.types.ints.unsigned;
            description = "Last slot in the band.";
          };
          size = lib.mkOption {
            type = lib.types.ints.positive;
            description = "How many slots the band holds.";
          };
          taken = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            description = ''
              Occupied slots in this band, as `"<slot>" = "<app>"`, counted by
              POSITION rather than by binding — an app whose slot landed in the
              wrong band still occupies the band it landed in.
            '';
          };
          free = lib.mkOption {
            type = lib.types.listOf lib.types.ints.unsigned;
            description = "Every free slot in the band, ascending.";
          };
          nextFree = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.unsigned;
            description = ''
              The LOWEST free slot in the band, which is the one the bottom-up
              fill convention asks for — or `null` when the band is full.

              Advice, never an assignment: a band is also ordered internally
              (an operator conventionally sits just below the instances it
              operates), and only the person adding the app knows which of those
              they are adding.
            '';
          };
          origins = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Declaring origins bound to this band.";
          };
        };
      });
      readOnly = true;
      default = lib.genAttrs bandNames reportOf;
      defaultText = lib.literalExpression "computed from `bands` and the slots the apps claim";
      description = ''
        WHAT IS WHERE, per band: which slots are taken and by what, which are
        free, and which one to hand the next app. Read-only, computed, and the
        answer to the only question this module refuses to answer by acting —
        where does a new app go.

        Ask it directly rather than reading a table somebody maintains by hand:

        ```
        nix eval .#nixidyEnvs.<env>.config.nixk3s.addressing.report.<band>.nextFree
        ```

        The eval errors and warnings this module raises quote it too, so the
        usual way to find out is simply to add the app and read what it says.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixidy.assertions =
      bandAssertions
      ++ lib.concatLists (lib.mapAttrsToList appAssertions enabledApps);

    nixidy.warnings =
      capacityWarnings
      ++ lib.concatLists (lib.mapAttrsToList appWarnings enabledApps);
  };
}
