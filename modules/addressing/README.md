# `nixk3s.addressing`

The **band model**: a repository binds a band, an app takes a slot inside it,
and a slot outside it fails eval.

```nix
{
  # Fleet layout — supplied privately, never shipped here.
  nixk3s.addressing = {
    enable = true;
    bands = {
      example-alpha = { base = 32; description = "one category of thing"; };
      example-beta = { base = 48; description = "another"; };
    };
    bindings.example-repo = "example-alpha";
    fallbackBand = "example-beta";
  };

  # An app declared by that repository.
  nixk3s.apps.example-web = {
    origin = "example-repo";
    slot = 33;
    # ... the rest of the app grammar
  };
}
```

## Three terms

| Term | What it is |
|---|---|
| **slot** | One number, held by one addressable workload. **Not an address** — an identity that the layers underneath map *into* addresses, usually into more than one space at once (an in-cluster address, an overlay peer, the DNS derived from either). |
| **band** | A contiguous run of slots — sixteen by default — reserved for one category of thing. |
| **binding** | A declaring module set (in practice: a repository) binds exactly **one** band. Every app it declares takes its slot from that band. |

One number driving several planes is the entire value of the model — one
registry, every front door — and equally the entire hazard: a slot that moves
moves all of them at the same instant.

## Binding is not optional

A repository that binds a band is one you can deploy into the cluster while
knowing where its services will land. A repository that binds none has to be
reasoned about one app at a time, forever. So while this module is enabled, an
app whose `origin` binds no band **fails eval**.

Where the right category is genuinely not obvious, bind the band `fallbackBand`
names — *deliberately*, as a decision somebody can find later. There is no
implicit fallback, and that is the point: an automatic one is how everything
ends up in the grab-bag band without anyone ever choosing it.

## A guard, not an allocator

This module will never assign a slot and never move one. Existing slots are
**live identities**: an allocator that tidied a band would rewrite an in-cluster
address and an overlay peer address in one commit, and the app would come back
somewhere other than where every consumer of it expects.

So it does exactly two things.

**It refuses**, at eval, naming the app, the number, the band the number landed
in and the band it belongs to:

```
app `example-control` claims slot 64, which is in `example-narrow` (a category
with room for exactly two) = slots 64..65, but its origin `example-repo-one`
binds `example-alpha` (one category of thing) = slots 32..47. A slot is one
identity in every address space the fleet maps it into, so nothing here will
move it for you — moving it changes all of them at once. Either give the app a
slot inside its own band (the next free slot in band `example-alpha` is 32), or
rebind its origin.
```

**It reports**, so the human adding an app is told the number instead of
guessing it:

```
nix eval .#nixidyEnvs.<env>.config.nixk3s.addressing.report.<band>.nextFree
```

`report.<band>` also carries `base`, `last`, `size`, `taken` (slot → app), `free`
and `origins`. In practice nobody runs it: an addressable app with no slot warns
with the number already in the message.

`nextFree` is the **lowest** free slot, because bands fill bottom-up. It stays
advice rather than an assignment for a second reason beyond safety: a band is
ordered internally too — an operator conventionally sits just below the
instances it operates — and only the person adding the app knows which of those
they are adding.

## Capacity is finite, and the error says so

A band holds `size` slots and nothing here can extend it. A band that fills up
therefore fails eval the moment another addressable app is bound to it:

```
app `example-narrow-three` renders a Service and so needs a slot, but its origin
`example-repo-narrow` binds `example-narrow` (a category with room for exactly
two) = slots 64..65, which is FULL — all 2 slots are taken by
`example-narrow-one`, `example-narrow-two`. A band cannot be extended. Bind this
origin to a band with room, or free a slot deliberately — reassigning one that
is in use changes a live address in every plane that slot feeds.
```

That is the whole reason capacity is checked: without it, the next person picks
a plausible-looking number, and a number from the neighbouring category is a
collision in every plane the slot feeds at once.

`warnFreeAtOrBelow` (default `2`) warns before that, while there is still room
to plan — and stays quiet about a band nobody has taken a slot in yet.

## What is public here, and what is not

> The mechanism is public. The layout is not.

This module declares the terms and knows **no band, no base, no slot and no
binding of its own**. Which category owns which run of the number space, and
which repository owns which category, is the shape of somebody's fleet — a value
the consumer supplies, exactly as `nixk3s.apps` takes its namespaces and node
paths.

| Term | Where the value comes from |
|---|---|
| `bands.<name>.base` / `.size` | private — where a category sits in the number space |
| `bindings.<origin>` | private — which repository owns which category |
| `fallbackBand` | private — which band is the grab-bag |
| `apps.<name>.slot` | private — a fleet fact, like `state.<n>.hostPath` |
| `apps.<name>.origin` | **public**: a repository naming *itself* is not fleet layout |

Nothing is rendered from a slot. The band model governs the number; what an
address looks like is the private layer's business, and it reads the option to
build one — a pinned ClusterIP is a typed merge onto the Service the app grammar
already rendered ([examples/all/private-overlay.nix](../../examples/all/private-overlay.nix)):

```nix
{ config, ... }:
{
  applications.example-web.resources.services.example-web.spec.clusterIP =
    "10.0.0.${toString config.nixk3s.apps.example-web.slot}";
}
```

## Stamping an origin once

One line per app is one line too many when a repository declares a dozen.
Definitions of an attrset of submodules merge, so stamp them all at once:

```nix
nixk3s.apps = lib.genAttrs [ "one" "two" "three" ] (_: { origin = "example-repo"; });
```

## Which apps need a slot

An app that renders a Service has an in-cluster address, which is what a slot
names — leaving `slot` null there warns (with the next free number) and is
refused outright once the band is full. A portless workload (a worker, a
cron-shaped process) addresses nothing and is never asked for one. Its origin
still binds a band, because every origin must.

## What it is checked against

`nix flake check` runs [`checks/addressing.nix`](../../checks/addressing.nix),
which proves both directions through real nixidy: a valid declaration renders
and the report counts it, while an out-of-band slot, a slot outside every band,
an app with no origin, an origin that binds nothing, a binding to a band nobody
declared, a fallback that does not exist, two apps on one slot, two bands over
one slot, and a full band each fail eval. The refusal *text* is asserted too —
an out-of-band message that does not name the app, the number and both bands
fails the check, because a guard that fires without saying what to do is only
half a guard.

## `enable` governs enforcement, not grammar

Switching the module off switches off the *policy*: bind a band, sit inside it,
do not run out of room. It does not switch off the *type* of a declaration. A
slot is a number and an origin is a name whether or not anything is currently
checking where the number lands, so those two — and every band's `base`, `size`
and `description` — are read by assertions that sit outside the `enable` gate,
and the check proves each ill-typed case is refused in **both** states of the
flag.

The alternative is worse than it sounds. A repository that has not turned the
model on yet is precisely the one accumulating slots nobody has looked at; if
`enable = false` meant "checked nothing", every one of those mistakes would
arrive at once on the day somebody switched it on. See
[`../../studies/what-forces-this-option.md`](../../studies/what-forces-this-option.md)
for the shape of the bug this closed — including why
`bands.<name>.description`, whose only reader is a helper used in messages, was
accepted as a number.
