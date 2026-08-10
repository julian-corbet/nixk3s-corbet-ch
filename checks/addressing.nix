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
#   - WHAT COUNTS AS ADDRESSABLE, in both directions, because both of them fail
#     silently: an app whose only published port sits on a companion needs a
#     slot even though it declares no `ports`, and an app that declares ports
#     and publishes none of them needs none even though it does;
#   - the MESSAGE, asserted by content: an out-of-band slot is only actionable
#     if the refusal names the app, the number, where it landed and where it
#     belongs, so the check reads the text and requires all four;
#   - the GRAMMAR, in both states of `enable`: an ill-typed slot, origin or band
#     description is refused with the model switched off as well as on, because
#     a type that only holds while a flag is set is not a type.
#
# Every band, base and slot below is invented for this file. The module ships
# none, and neither does this check: what is being verified is the mechanism.
{ pkgs, lib, nixidy, appsModule, addressingModule }:
let
  base = {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";

    # The GPU cases below declare `gpu = true`, and the apps module refuses that
    # until the cluster names the device it advertises (a wrong guess there
    # schedules a device-less pod silently). Naming it is what lets this check
    # exercise the override at all.
    nixk3s.appPlatform.gpuResourceName = "example.com/gpu";

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
        # The band the GPU override pulls into, so that the one rule allowing a
        # repository to address into two bands is exercised rather than described.
        example-burn = {
          base = 96;
          description = "the category for workloads that burn the shared device";
        };
      };

      bindings = {
        example-repo-one = "example-alpha";
        example-repo-narrow = "example-narrow";
      };

      fallbackBand = "example-alpha";
      gpuBand = "example-burn";
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

    # THE GPU OVERRIDE, PROVED BY ITS REFUSAL. Slot 33 is inside `example-alpha`,
    # which is exactly the band this app's origin binds — so without the override
    # this declaration is the control case and passes. It must FAIL here, because
    # burning the device moves the app to `example-burn` whatever its origin
    # bound. A check that only asserted the passing direction could not tell the
    # override from a no-op.
    gpu-app-in-its-origins-band-instead-of-the-gpu-band = goodApp // { gpu = true; };

    # And the override does not hand out a licence to sit anywhere: a burning app
    # outside the GPU band is refused just as squarely as a non-burning one
    # outside its origin's.
    gpu-app-outside-the-gpu-band = goodApp // { gpu = true; slot = 64; };
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

    # A `gpuBand` naming nothing must fail LOUDLY. The failure mode it guards is
    # the quiet one: `boundBandOf` would fall through to the origin's binding, so
    # every burning app would go back to being judged against its repository's
    # band with the guard still reporting green.
    gpu-band-that-does-not-exist = {
      nixk3s.addressing.gpuBand = lib.mkForce "example-nonexistent";
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

    # WHAT "ADDRESSABLE" MEANS, in the direction that fails silently. This app
    # declares no `ports` of its own, so anything asking "does it have ports"
    # concludes it needs no address — while it renders a Service on its
    # COMPANION's port and genuinely does. The band is full, so the only way
    # this renders green is if the guard was never asked; the module must read
    # the app's own `rendersService` rather than re-derive the fact.
    an-app-addressed-through-its-companion-bound-to-a-full-band = {
      nixk3s.apps = {
        example-narrow-one = goodApp // { origin = "example-repo-narrow"; slot = 64; };
        example-narrow-two = goodApp // { origin = "example-repo-narrow"; slot = 65; };
        example-narrow-front = {
          image = goodApp.image;
          origin = "example-repo-narrow";
          companions.web = { image = goodApp.image; ports.http.number = 8080; };
        };
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
  ## The grammar, which `enable` does not govern
  ##
  ## `enable` switches on the POLICY — bind a band, sit inside it, do not run
  ## out of room. It does not switch off the TYPE of a declaration, so each case
  ## below must be refused in BOTH states of the flag. Before that split
  ## existed, a repository that had not turned the model on yet accepted
  ## `slot = "soon"` and rendered green, and met every one of them at once on
  ## the day somebody enabled it.
  ##
  ## These go through `renders` alone and never through `failures`: an ill-typed
  ## definition throws while the assertion list is being BUILT, so there is no
  ## message to read and asking for one would throw rather than return. Which is
  ## also why `silentlyRefused` above must not be extended to cover them.
  ## ---------------------------------------------------------------------

  mkEnvOff = values: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [
      appsModule
      addressingModule
      base
      { nixk3s.addressing.enable = lib.mkForce false; }
      values
    ];
  };

  rendersOff = values:
    (builtins.tryEval (builtins.seq (mkEnvOff values).environmentPackage.drvPath true)).success;

  illTyped = {
    slot-that-is-not-a-number = {
      nixk3s.apps.example-control = goodApp // { slot = "thirty-three"; };
    };

    origin-that-is-not-a-name = {
      nixk3s.apps.example-control = goodApp // { origin = 1; };
    };

    # THE MESSAGE-ONLY SHAPE, which a search for unrendered options misses:
    # `description` is read by `showBand` and by nothing else, and `showBand`'s
    # own callers are all assertion and warning messages — which the module
    # system formats only for the assertions that have already failed. So the
    # option was declared, typed, accepted, and never once evaluated.
    band-description-that-is-not-a-string = {
      nixk3s.apps.example-control = goodApp;
      nixk3s.addressing.bands.example-alpha.description = lib.mkForce 12345;
    };

    # The same hole, proven the other way round: a value that cannot be
    # evaluated at all is indistinguishable from a good one until something
    # evaluates it.
    band-description-that-throws = {
      nixk3s.apps.example-control = goodApp;
      nixk3s.addressing.bands.example-alpha.description =
        lib.mkForce (throw "a description nothing reads is a description nothing checks");
    };
  };

  wronglyRenderedIllTyped =
    lib.attrNames (lib.filterAttrs (_: v: v) (lib.mapAttrs (_: renders) illTyped));

  wronglyRenderedIllTypedWhileOff =
    lib.attrNames (lib.filterAttrs (_: v: v) (lib.mapAttrs (_: rendersOff) illTyped));

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
      # THE OVERRIDE'S PASSING DIRECTION, and the whole point of it: one origin
      # legitimately addressing into two bands. `example-repo-one` binds
      # `example-alpha` and `example-control` above sits there at 33 — while this
      # app, from the SAME origin, sits at 96 in `example-burn` because it burns
      # the device. Both render, and neither needed a per-app escape.
      example-burner = goodApp // { gpu = true; slot = 96; };
    };
  };

  controlRenders = renders goodValues;

  # THE SAME PREDICATE, THE OTHER WAY ROUND, and it needs a full band of its own
  # to be worth anything. Every port this app declares is unpublished, so it
  # renders no Service and holds no address — bound to a band with no room left,
  # it must STILL render, because nothing asks a workload with no address for a
  # number. Under a "does it have ports" predicate this is an eval failure, and
  # the two cases together are the only way to tell a working guard from a guard
  # that says yes to everything.
  unpublishedInAFullBand = withControl {
    nixk3s.apps = {
      example-narrow-one = goodApp // { origin = "example-repo-narrow"; slot = 64; };
      example-narrow-two = goodApp // { origin = "example-repo-narrow"; slot = 65; };
      example-narrow-quiet = {
        image = goodApp.image;
        origin = "example-repo-narrow";
        ports.metrics = { number = 9100; publish = false; };
      };
    };
  };

  unpublishedPortNeedsNoSlot = renders unpublishedInAFullBand;

  # The same declaration with the model switched off. Without it, "everything
  # fails while `enable` is false" would read as proof that the grammar is
  # checked there — a check that refuses every declaration proves only that it
  # is a wall.
  controlRendersWhileOff = rendersOff goodValues;

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
  (lib.throwIf (!controlRendersWhileOff)
    ("nixk3s.addressing: the control declaration does not render with `enable = false`, so the grammar "
      + "cases below prove only that the module refuses everything while it is switched off.")
    (lib.throwIf (!unpublishedPortNeedsNoSlot)
      ("nixk3s.addressing asked for a slot from an app that publishes no ports and therefore renders no "
        + "Service. It has no in-cluster address to name, and the band it is bound to is full — so this "
        + "is an app refused for an address it does not have. `addressable` must read the app's own "
        + "`rendersService`, not whether it happens to declare a port.")
      (lib.throwIf (wronglyRenderedIllTyped != [ ])
        ("nixk3s.addressing accepted ill-typed declarations with the band model ENABLED: "
          + lib.concatStringsSep ", " wronglyRenderedIllTyped)
        (lib.throwIf (wronglyRenderedIllTypedWhileOff != [ ])
          ("nixk3s.addressing accepted ill-typed declarations with the band model DISABLED: "
            + lib.concatStringsSep ", " wronglyRenderedIllTypedWhileOff
            + ". A type that only holds while a flag is set is not a type — the value is being declared "
            + "either way, and the repository that has not switched the model on yet is exactly the one "
            + "accumulating the mistakes.")
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

                          and the grammar is checked whether or not the model is enforced —
                          each of these is refused with `enable` both true and false:
                          ${lib.concatMapStringsSep "\n" (n: "  refused  ${n}") (lib.attrNames illTyped)}

                          and it says why — the out-of-band slot:

                          ${outOfBandMessage}

                          the full band:

                          ${fullBandMessage}

                          the warnings, before either becomes an error:

                          ${warnedText}
                        ''))))))))))))
