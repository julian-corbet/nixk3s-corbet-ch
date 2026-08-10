# What forces this option?

**Finding:** in this module system an option's type is checked only when something evaluates the
value. Declaring the option, accepting a definition for it, and then never reading it is not an
error — it is silence. `nixk3s.apps.<name>.replicas = "not-a-number"` rendered a green
`nix flake check`, and so did `bands.<name>.description = throw "…"`.

Four options in this repository were in that state. All four were typed, all four were documented,
none of them was checked.

## Two shapes, and only one of them is easy to find

A sibling repository had already found the message-only shape and written it up as
[*an option nothing renders is never checked*](https://github.com/julian-corbet/nixwatch-corbet-ch/blob/main/studies/an-option-nothing-renders-is-never-checked.md):
the module system keeps only the FAILING assertions and formats those, so a value mentioned solely
inside an assertion message is never evaluated, and *you cannot force a value by mentioning it in a
message*. That is true, it is the reason this repository's `addressing` module carries a comment
saying so, and it is what a reviewer goes looking for once they know about it.

It is also only half the problem, and the easier half. A search for "which values appear only in
messages" finds nothing wrong with this:

```nix
replicas = lib.mkIf (app.scaling == "always") app.replicas;
```

`replicas` is read by the renderer, in the object that actually ships, on the line the option's
documentation points at. It is nonetheless unchecked for every app that sleeps, because `mkIf` with
a false condition discards its content unevaluated. The same thing happens one level down inside an
ordinary `if`:

```nix
if st.claim != null
then { persistentVolumeClaim.claimName = st.claim; }
else { hostPath = { path = st.hostPath; type = st.hostPathType; }; }
```

and again in a `&&` that short-circuits before reaching its second term. None of those look like the
message bug. They look like code that reads the value — which it does, on one branch, for one kind
of declaration.

So the two shapes are worth naming separately:

- **MESSAGE-ONLY.** Every read site is an assertion or warning message. Nothing evaluates it until
  the guard beside it has already failed. Found by asking *where is this read?*
- **BRANCH-SHADOWED.** The read sites are real renders, but each sits behind an `mkIf`, an `if`, an
  `optionalAttrs`, or the far side of a short-circuit — so the value is checked for one shape of
  declaration and silently accepted for the other. Found only by asking *is it read on **every**
  path?*, which is a different question and a much less natural one.

A third shape belongs beside them, because it produced two of the four findings here at once:

- **GUARD-SHADOWED.** Everything about a term is read, correctly, on every path — inside
  `config = lib.mkIf cfg.enable { … }`. With the module switched off, the whole validation layer is
  gone and every option it governs accepts anything. This is the widest of the three: it does not
  affect one option but all of them, and it affects exactly the consumers who have not adopted the
  feature yet, which is to say the ones with the least reason to have looked.

## What shipped

**`apps.<name>.replicas`** and **`state.<vol>.hostPathType`** each gained an assertion that reads
the value as its FIRST term, so the read no longer depends on which branch the declaration takes.
Both turned out to make a real guard as well, which is the usual outcome: the reason a value is
unread on some path is that it means nothing on that path, and saying so out loud is a better answer
than dropping it.

```nix
assertion = app.replicas == 1 || app.scaling == "always";
```

**`slot`**, **`origin`** and every band's **`base`**, **`size`** and **`description`** moved out from
behind `config = lib.mkIf cfg.enable`. The module's `config` is now an `mkMerge` of an unconditional
grammar block and the gated policy block, on the principle that

> `enable` governs the POLICY — must an origin bind a band, must a slot sit inside it. It does not
> govern the GRAMMAR. A type that only holds while a flag is set is not a type.

The description was the message-only case, and the fix is the one that reads oddly out of context:

```nix
assertion = showBand band != "";
```

`showBand` is the display helper whose four other callers are all messages, so reading it from an
assertion EXPRESSION is the only thing in the file that evaluates a band's description at all. It
can never be false. Being false is not its job.

## The lower-priority ones, and why nothing shipped for them

`report.<band>.taken`, `.origins`, `.base`, `.last` and `.size` are unforced too — `.size` has zero
read sites anywhere in the repository. So is `appPlatform.rawEscapeHatchApps`. All of them are
`readOnly` with a computed default, which means the only value their type can ever see is one this
module produced itself. A type there is documentation for the reader, not a guard against the
consumer, and an assertion forcing it would check this repository's arithmetic against itself.

The distinction is worth keeping sharp, because "unforced" alone is not a finding: **an unforced
option matters exactly as much as a consumer can put something wrong in it.**

## It recurs, and that is the useful part

Two more BRANCH-SHADOWED options arrived with the next extension of the app grammar, and both were
found by running question 2 against the diff rather than by noticing anything:

- **`state.<vol>.items`** — which keys a ConfigMap- or Secret-backed volume projects. `itemsOf`
  reads it on the two *keyed* branches of a five-way backing chain and nowhere else, so beside a
  claim, a node path or a scratch directory the value was accepted and discarded. It is now read by
  a guard that runs for every entry, and — the usual outcome again — the guard is real: `items`
  beside a backing that has no keys describes a projection that does not exist.
- **`ports.<n>.servicePort`** — the number the Service publishes. `mkService` is its only reader,
  and that call moved behind `rendersService` when a port gained the ability to decline publication.
  So on an app that publishes nothing, `servicePort` became unreachable in exactly the way
  `replicas` is unreachable on an app that sleeps. Same fix, same second payoff: a `servicePort` on
  an unpublished port is a fact about an entry of a Service that will never carry it.

The second one is worth dwelling on, because nothing about it was a mistake in the new option. It
was a mistake in the *call site*: adding `publish` put an existing, correctly-read option behind a
new branch. **Question 2 has to be asked again every time a render site gains a condition**, not
only when an option is added.

## The general shape, for the next module in this family

Ask it per option, and ask the harder version:

1. **What forces this?** If the answer is "a message", it is unchecked.
2. **Is it forced on EVERY path?** If the answer is "on the branch that renders it", it is unchecked
   for the other branch. `mkIf`, `if/else`, `optionalAttrs` and `&&`/`||` all hide this equally well.
3. **Is the thing that forces it inside a `mkIf cfg.enable`?** Then it is unchecked for everybody who
   has not switched the feature on.
4. **Can a consumer set it at all?** `readOnly` with a default answers *no*, and there is nothing to
   fix.

And in the checks, two rules that the cases here would have passed without:

- **A negative case must perturb only the discarded value, against a control in the same shape.** A
  case that declares `scaling = "scale-to-zero"` and a bad `replicas` proves nothing on its own: the
  refusal might be about scale-to-zero. `checks/apps-fail-closed.nix` therefore carries one control
  per branch it needs to hold open — plain, sleeping, claim-backed, multi-container, identity-bearing,
  and both directions of "publishes a port" — and every one of them must render.
- **A flag-gated guard needs its cases run in both states of the flag.** `checks/addressing.nix`
  builds a second environment with `enable = lib.mkForce false` and requires the same ill-typed
  declarations to be refused there, plus a valid one to still render, so "refuses everything while
  disabled" cannot pass for a proof.

Ill-typed cases go through the render (`tryEval` on `environmentPackage.drvPath`) and never through
the assertion list: a type violation throws while the list is being BUILT, so there is no message to
read, and a check that asked for one would throw rather than report.
