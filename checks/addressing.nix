# Proves the band model in BOTH directions, because a guard nobody has watched
# fire is a comment, and a guard that fires on everything is a wall.
#
#   - the positive direction: a declaration that obeys the model renders, and
#     the report counts what it claimed — including the number it would hand
#     the next app, which is the only answer this module gives to "where does a
#     new app go";
#   - the failing direction: a slot outside its repository's band, a slot
#     outside every band, an app with no origin, an origin that binds nothing, a
#     binding to a band nobody declared, a fallback that does not exist, two
#     apps on one slot, two bands over one slot, and a full band each fail eval;
#   - the MESSAGE, asserted by content: an out-of-band slot is only actionable
#     if the refusal names the app, the number, where it landed and where it
#     belongs, so the check reads the text and requires all four.
#
# Every band, base and slot below is invented for this file. The module ships
# none, and neither does this check: what is being verified is the mechanism.
{ pkgs, lib, nixidy, appsModule, addressingModule }:
let
  base = {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";

    nixk3s.addressing = {
      enable = true;

      bands = {
        example-alpha = {
          base = 32;
          description = "one category of thing";
        };
        # Two slots wide, so "this band is full" is reachable in a check instead
        # of only in a fleet that has been running for years.
        example-narrow = {
          base = 64;
          size = 2;
          description = "a category with room for exactly two";
        };
      };

      bindings = {
        example-repo-one = "example-alpha";
        example-repo-narrow = "example-narrow";
      };

      fallbackBand = "example-alpha";
    };
  };

  # A declaration that is fine on its own; each case below perturbs one thing.
  goodApp = {
    image = "registry.example.com/example-org/example-app:1.0.0@sha256:3333333333333333333333333333333333333333333333333333333333333333";
    ports.http.number = 8080;
    origin = "example-repo-one";
    slot = 33;
  };

  mkEnv = values: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule addressingModule base values ];
  };

  renders = values:
    (builtins.tryEval (builtins.seq (mkEnv values).environmentPackage.drvPath true)).success;

  # The assertions themselves, rather than the throw they eventually cause:
  # `tryEval` can only say THAT a render was refused, and half of what is being
  # checked here is what the refusal says.
  failures = values:
    map (a: a.message)
      (lib.filter (a: !a.assertion) (mkEnv values).config.nixidy.assertions);

  fired = values:
    map (w: w.message) (lib.filter (w: w.when) (mkEnv values).config.nixidy.warnings);

  ## ---------------------------------------------------------------------
  ## The failing direction
  ## ---------------------------------------------------------------------

  # Cases that perturb the app; each is rendered as the only app in the env.
  appCases = {
    # THE GUARD: a real slot, in a real band, that is not this repository's
    # band. Nothing here moves it — the number is already an identity in every
    # address space the fleet maps it into.
    slot-outside-its-repositorys-band = goodApp // { slot = 64; };

    slot-outside-every-declared-band = goodApp // { slot = 200; };

    app-that-names-no-origin = goodApp // { origin = null; };

    origin-that-binds-no-band = goodApp // { origin = "example-repo-unbound"; };
  };

  # Cases that perturb the model itself; each keeps one valid app alongside, so
  # what fails is the model and not an empty render.
  modelCases = {
    binding-to-a-band-nobody-declared = {
      nixk3s.addressing.bindings.example-repo-one = lib.mkForce "example-nonexistent";
    };

    fallback-band-that-does-not-exist = {
      nixk3s.addressing.fallbackBand = lib.mkForce "example-nonexistent";
    };

    two-bands-over-one-slot = {
      nixk3s.addressing.bands.example-overlap = { base = 33; size = 4; };
    };

    two-apps-on-one-slot = {
      nixk3s.apps.example-second = goodApp;
    };

    # The band holds two, both are taken, and a third addressable app is bound
    # to it. This is the case that must NOT arrive as a collision: it arrives as
    # "this band is full", at eval, naming what fills it.
    an-app-bound-to-a-full-band = {
      nixk3s.apps = {
        example-narrow-one = goodApp // { origin = "example-repo-narrow"; slot = 64; };
        example-narrow-two = goodApp // { origin = "example-repo-narrow"; slot = 65; };
        example-narrow-three = goodApp // { origin = "example-repo-narrow"; slot = null; };
      };
    };
  };

  withControl = values: lib.recursiveUpdate { nixk3s.apps.example-control = goodApp; } values;

  mustFail =
    lib.mapAttrs (_: app: { nixk3s.apps.example-control = app; }) appCases
    // lib.mapAttrs (_: withControl) modelCases;

  wronglyRendered =
    lib.attrNames (lib.filterAttrs (_: v: v) (lib.mapAttrs (_: renders) mustFail));

  # Every case must also produce a message; a case refused by the wrong guard,
  # or by a type error, would otherwise pass this check silently.
  silentlyRefused =
    lib.attrNames (lib.filterAttrs (_: values: failures values == [ ]) mustFail);

  ## ---------------------------------------------------------------------
  ## What the refusal SAYS
  ## ---------------------------------------------------------------------

  outOfBandMessage =
    lib.concatStringsSep "\n" (failures mustFail.slot-outside-its-repositorys-band);

  # An out-of-band refusal is only actionable if it names all four: which app,
  # which number, the band the number is in, and the band it should be in.
  requiredInMessage = [
    "example-control" # the app
    "64" # the slot it claimed
    "example-narrow" # the band that number is in
    "example-alpha" # the band its origin bound
    "32" # ... and where that band starts, so "which number instead" is answerable
  ];

  missingFromMessage = lib.filter (s: !(lib.hasInfix s outOfBandMessage)) requiredInMessage;

  fullBandMessage =
    lib.concatStringsSep "\n" (failures mustFail.an-app-bound-to-a-full-band);

  missingFromFullMessage =
    lib.filter (s: !(lib.hasInfix s fullBandMessage)) [ "FULL" "example-narrow" "example-narrow-three" ];

  ## ---------------------------------------------------------------------
  ## The positive direction
  ## ---------------------------------------------------------------------

  # One app on a slot inside its own band, plus a portless one with no slot at
  # all — which is not an omission: nothing addresses a workload that renders no
  # Service, so nothing asks it for a number.
  goodValues = {
    nixk3s.apps = {
      example-control = goodApp;
      example-worker = {
        image = goodApp.image;
        origin = "example-repo-narrow";
      };
    };
  };

  controlRenders = renders goodValues;

  report = (mkEnv goodValues).config.nixk3s.addressing.report;

  # The report is the whole of this module's answer to "where does the next app
  # go", so its arithmetic is checked rather than trusted.
  reportFacts = [
    {
      what = "the band's first slot";
      expected = "32";
      actual = toString report.example-alpha.base;
    }
    {
      what = "the band's last slot";
      expected = "47";
      actual = toString report.example-alpha.last;
    }
    {
      what = "the claimed slot is counted, by app";
      expected = "example-control";
      actual = report.example-alpha.taken."33";
    }
    {
      what = "fifteen of sixteen left";
      expected = "15";
      actual = toString (lib.length report.example-alpha.free);
    }
    {
      # BOTTOM-UP, and the reason it is advice: the lowest free slot is 32,
      # BELOW the one already taken. An allocator would have handed out 34.
      what = "the next free slot is the lowest one, not the next one up";
      expected = "32";
      actual = toString report.example-alpha.nextFree;
    }
    {
      what = "the origins bound to the band";
      expected = "example-repo-one";
      actual = lib.concatStringsSep " " report.example-alpha.origins;
    }
    {
      what = "a portless app claims nothing";
      expected = "0";
      actual = toString (lib.length (lib.attrNames report.example-narrow.taken));
    }
  ];

  wrongFacts = lib.filter (f: f.expected != f.actual) reportFacts;

  # A full band reports no next slot at all — the same fact the eval error is
  # made of, read from the other side.
  fullReport = (mkEnv (withControl {
    nixk3s.apps = {
      example-narrow-one = goodApp // { origin = "example-repo-narrow"; slot = 64; };
      example-narrow-two = goodApp // { origin = "example-repo-narrow"; slot = 65; };
    };
  })).config.nixk3s.addressing.report;

  fullBandHasNoNextSlot = fullReport.example-narrow.nextFree == null;

  ## ---------------------------------------------------------------------
  ## Warnings — the notice that arrives while there is still room to plan
  ## ---------------------------------------------------------------------

  # One of the narrow band's two slots is taken, so it is at (and below) the
  # default warning threshold; and an addressable app with no slot is told the
  # number to use rather than left to guess it.
  warned = fired (withControl {
    nixk3s.apps = {
      example-narrow-one = goodApp // { origin = "example-repo-narrow"; slot = 64; };
      example-narrow-two = goodApp // { origin = "example-repo-narrow"; slot = null; };
    };
  });

  warnedText = lib.concatStringsSep "\n" warned;

  missingWarnings = lib.filter (s: !(lib.hasInfix s warnedText)) [
    "free slot(s) left" # the band is filling up
    "claims no slot" # this app has not taken one
    "the next free slot in band `example-narrow` is 65" # ... and here is the number
  ];
in
lib.throwIf (!controlRenders)
  "nixk3s.addressing: the control declaration does not render, so every negative case below proves nothing."
  (lib.throwIf (wronglyRendered != [ ])
    ("nixk3s.addressing rendered declarations it must have refused: "
      + lib.concatStringsSep ", " wronglyRendered)
    (lib.throwIf (silentlyRefused != [ ])
      ("nixk3s.addressing refused these without an assertion message, so something other than its own "
        + "guards stopped them: " + lib.concatStringsSep ", " silentlyRefused)
      (lib.throwIf (missingFromMessage != [ ])
        ("nixk3s.addressing refused an out-of-band slot with a message that never says "
          + lib.concatStringsSep ", " missingFromMessage + ":\n" + outOfBandMessage)
        (lib.throwIf (missingFromFullMessage != [ ])
          ("nixk3s.addressing refused an app on a full band without saying "
            + lib.concatStringsSep ", " missingFromFullMessage + ":\n" + fullBandMessage)
          (lib.throwIf (wrongFacts != [ ])
            ("nixk3s.addressing reports the wrong occupancy: "
              + lib.concatMapStringsSep "; "
              (f: "${f.what}: expected ${f.expected}, got ${f.actual}")
              wrongFacts)
            (lib.throwIf (!fullBandHasNoNextSlot)
              "nixk3s.addressing offers a next free slot in a band that is full."
              (lib.throwIf (missingWarnings != [ ])
                ("nixk3s.addressing never warned about " + lib.concatStringsSep ", " missingWarnings
                  + ". What it warned about instead:\n" + warnedText)
                (pkgs.writeText "nixk3s-addressing" ''
                  the control renders, and the report counts it:
                  ${lib.concatMapStringsSep "\n" (f: "  ok       ${f.what}: ${f.actual}") reportFacts}

                  every guard fires:
                  ${lib.concatMapStringsSep "\n" (n: "  refused  ${n}") (lib.attrNames mustFail)}

                  and it says why — the out-of-band slot:

                  ${outOfBandMessage}

                  the full band:

                  ${fullBandMessage}

                  the warnings, before either becomes an error:

                  ${warnedText}
                ''))))))))
