# nixk3s

**Bare-metal k3s on NixOS with a fully declarative GitOps spine: nixidy
renders, Argo CD reconciles, the host is a flake.**

The cluster foundation of an interoperating project set: one NixOS host (or a
few) running k3s, with every workload defined in Nix, rendered to plain
manifests by [nixidy](https://github.com/arnarg/nixidy), and synced by Argo CD
with prune + self-heal. No hand-applied YAML, no helm-on-the-CLI, no drift.

## The pitch

Running k3s on NixOS is easy. Running it *declaratively end-to-end* — host
config, cluster bootstrap, workload manifests, image delivery, tenancy — is a
pile of decisions everyone makes alone. `nixk3s` packages one coherent,
production-lived answer:

- **The host is a flake.** k3s server config, node labels, storage paths —
  all NixOS options, all reproducible.
- **Workloads are Nix too.** nixidy renders typed Nix modules to a plain
  manifest tree; Argo CD (prune + selfHeal) reconciles the cluster to git.
  The rendered tree is a build artifact you can read, diff, and audit.
- **Airgapped images.** Custom images are imported declaratively on the host
  (`services.k3s.images`) — no registry required for cluster-internal pieces.
- **Tenancy by AppProject.** A small, opinionated project model separating
  the things that *manage* the cluster from the things that *run on* it.

## What ships

- **`k3s-host`** (`nixosModules.k3s-host`, landed) — the NixOS side: k3s
  server with sane bare-metal defaults, declarative node labels, airgap image
  import.
- **`tenancy`** (`nixidyModules.tenancy`, landed) — the AppProject tenancy
  model and its allowed-destination conventions.
- **`apps`** ([`nixidyModules.apps`](modules/apps), landed) — the app grammar:
  an app declares what it NEEDS (an image, ports, an exposure class, whether it
  scales to zero, which existing claims or node paths hold its state, which
  existing Secrets it consumes) and this renders the Application, an optional
  Namespace, a Deployment and a Service. Options are parameters: the vocabulary
  names objects and classes and takes every fleet fact from its consumer, which
  is what lets it be public while the clusters it renders for stay private.
  Two visible ways out for what it has no term for — a typed merge onto the
  objects it renders, and a countable `raw` escape hatch.
- **`addressing`** ([`nixidyModules.addressing`](modules/addressing), landed) —
  the band model: a declaring repository binds one *band* (a contiguous run of
  slots), every app it declares takes its *slot* inside that band, and a slot
  outside it fails eval. A slot is not an address — it is the identity the
  layers underneath map into however many address spaces a fleet keeps, which
  is why this is a **guard, not an allocator**: nothing here assigns a slot or
  moves one, because moving one moves every plane it feeds at the same instant.
  It refuses (naming the app, the number and both bands) and it reports the next
  free slot; the human decides. Bands are finite, so a band that fills up says
  so at eval instead of becoming a collision. Every band, base and binding is a
  value the consumer supplies — the mechanism is public, the layout is not.
- **`cockpit`** ([`nixidyModules.cockpit`](modules/cockpit), landed) — the
  platform's own faces: the surfaces you open to find out whether the cluster
  that runs your apps is working, catalogued and translated into the grammar
  above. It is the one catalogue of particular software in a repository that is
  otherwise pure mechanism, and it does not contradict that — nothing in it is
  an app you *have*. **A face belongs only if it would still be worth running on
  a cluster with no apps in it**: delete every workload and the catalogue is
  unchanged and still has a job, while a catalogue of "apps you run" is empty
  there. The dependency runs one way (the cockpit imports the grammar; the
  grammar cannot see the cockpit) and it is deliberately **not** part of
  `nixidyModules.default`, because importing everything must not hand anyone an
  opinion about which dashboards exist.
- **[docs/SPINE.md](docs/SPINE.md)** (landed) — the GitOps spine pattern:
  nixidy render → commit → Argo CD sync, with the rendered tree excluded from
  the render trigger (no loops).

## Status

**Pre-alpha, fully dogfooded.** The spine is real: it runs a production
single-node cluster (15+ Argo applications, GPU workloads, the whole works)
and has survived node rebuilds and a bare-metal migration — and since
2026-07-22 that cluster runs the host and tenancy modules from this repo: its
k3s server config comes from `k3s-host`, and its entire Argo CD project layer
(11 AppProjects + 5 protected namespace anchors) is rendered by `tenancy`,
adopted in-place with a semantically-verified zero-drift cutover (the
module + consumer values reproduced the live objects field-exactly). The same
cluster now declares 40 workloads through `apps`; eight exercise its ordered
init-container vocabulary, and 16 still carry at least one whole object through
the visible `raw` escape hatch. `addressing` guards every one of those app slots
against the declaring repository's bound band. The remaining raw objects are a
measured migration tail, not a second application model.

The repository can also demonstrate that its modules evaluate, on its own, in
seconds: `nix flake check` renders `tenancy`, `apps`, `addressing` and `cockpit`
through real nixidy and composes `k3s-host` into a NixOS system, from the
placeholder configs in [examples/](examples). All are proven in the failing direction too —
a bad `role` value and an undefined tenancy option each fail the corresponding
check, the app grammar's twenty guards each get a declaration that violates them
and must be refused, against a control declaration that must render, and the
band model is checked the same way plus one step further: the *text* of its
refusal is asserted, because a guard that fires without naming the app, the
number and both bands is only half a guard.

`cockpit` is checked the same way in both directions, and its render check reads
the split back off the bytes: the port, the page each probe GETs and the
container-internal paths arrive from the catalogue with the declaration never
stating one, while the numbers those probes are budgeted with arrive from the
declaration with the catalogue carrying none — a threshold is a stopwatch held
against one cluster's disks, and one measured on somebody else's hardware is a
restart loop on yours. The database lands inside the directory the declaration
backs, the identity the image drops to arrives as two numbers while the pod
carries no security context of its own, the probe the catalogue *refuses* is
absent from the manifest and cannot be budgeted into it, and the value that must
survive every restart unchanged is a reference and never a literal. The env that renders it composes the cockpit *alone* — the
grammar comes with it — while the env that renders the grammar composes it
without the cockpit, which is what keeps "you can take the grammar without the
catalogue" a checked claim rather than a promise.

`apps` goes one step further than evaluating: `checks/apps-render.nix` parses
the manifests the grammar actually produced and asserts them field by field,
because a module that type-checks can still render a Deployment whose selector
misses its own pods — not an eval error, just an outage. The same check renders
an example private overlay on top of the grammar and asserts that a consumer's
own fields (a pinned address, an identity, a pod-spec knob the vocabulary has no
term for) land on the objects without displacing what the grammar rendered.

Until this landed, `nixidy` was not a flake input here and there was no `checks`
output at all, so nothing in CI evaluated either module. That never made the
dogfooding above less true; it just meant the repository could not show its work.

Note the narrowness: the host check evaluates the configuration, it does not boot
a machine. The example config mounts `tmpfs` on `/` and could never boot anything,
which is deliberate — it exists to type-check a module, not to describe hardware.

## Related projects

- [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) — priority-based
  single-GPU sharing built on this spine.
- [nixllm](https://github.com/julian-corbet/nixllm-corbet-ch) — the shared
  LLM serving lane running on that substrate.
- [nixapps](https://github.com/julian-corbet/nixapps-corbet-ch) — curated
  nixidy app modules that deploy onto it.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
