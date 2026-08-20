# Reads the cockpit's promises back off the RENDERED BYTES, not off the options that produced them.
#
# The eval check proves the module resolves and refuses. This one proves the manifests that come
# out say what the module claims, which is a different question and the only one a cluster ever
# sees: a translator can resolve every option correctly and still mount the wrong path, write a
# database onto the pod's own filesystem, or carry a uid nothing reads.
#
# The assertions below are the module's PROMISES, not a transcript of today's output. A parked
# declaration renders nothing at all; the catalogue's port, the page its probes GET and the
# container-internal paths reach the objects without a declaration having stated one, while the
# numbers those probes are budgeted with reach the same objects without the catalogue carrying one;
# the database sits INSIDE the directory something backs; the identity the image drops to arrives
# as two numbers and the pod carries no security context of its own; the key that must never change
# arrives by reference and never as a value; a directory that must already exist is mounted with
# the backing that refuses to create one; and the Service is a plain in-cluster address with
# nothing pinned.
{ pkgs, lib, env }:

pkgs.runCommand "nixk3s-cockpit-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
  # Not a manifest, and the only place the band model is visible in a rendered tree: it governs a
  # number and renders nothing from it, so the check reads the position off the config and asserts
  # that no object grew an address out of it.
  portalSlot = toString env.config.nixk3s.apps.example-portal.slot;
} ''
  set -euo pipefail
  fail=0
  check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "  ok   $1: $3"
    else echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
  }
  y() { yq -r "$1" "$2"; }

  echo "== a parked declaration renders nothing: one surface in the tree, not two =="
  rendered=$(ls "$manifests" | sort | tr '\n' ' ' | sed 's/ $//')
  check "rendered surfaces" "apps example-portal" "$rendered"

  portal="$manifests/example-portal"
  deploy="$portal/Deployment-example-portal.yaml"
  svc="$portal/Service-example-portal.yaml"
  app="$manifests/apps/Application-example-portal.yaml"

  # `-L` is load-bearing: the rendered tree is SYMLINKS into the store, so a plain `-type f`
  # matches nothing and returns a confident zero. A count that can only ever be zero is worse than
  # no check, because it passes the moment somebody expects zero.
  check "applications rendered" "1" "$(find -L $manifests/apps -name 'Application-*.yaml' -type f | wc -l)"

  echo "== the catalogue supplies the port, and the declaration never stated one =="
  check "container port" "7575" "$(y '.spec.template.spec.containers[0].ports[0].containerPort' $deploy)"
  check "service port"   "7575" "$(y '.spec.ports[0].port' $svc)"

  echo "== an embedded database is single-writer, so its Deployment may not roll =="
  check "strategy" "Recreate" "$(y '.spec.strategy.type' $deploy)"
  # An absent `replicas` IS one -- Kubernetes' own default. Asserting it is unset is the honest
  # form: a sleeping workload's count belongs to its wake front, and the Application says so.
  check "replicas unset (the wake front owns it)" "null" "$(y '.spec.replicas' $deploy)"
  check "application ignores that field" "/spec/replicas" "$(y '.spec.ignoreDifferences[0].jsonPointers[0]' $app)"

  echo "== the directory that must already exist is mounted by a backing that refuses to create one =="
  check "mount path"     "/appdata"                        "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' $deploy)"
  check "backing path"   "/example/state/example-portal"   "$(y '.spec.template.spec.volumes[0].hostPath.path' $deploy)"
  check "backing type"   "Directory"                       "$(y '.spec.template.spec.volumes[0].hostPath.type' $deploy)"
  check "node pin is stated" "example-node"                "$(y '.spec.template.spec.nodeSelector."kubernetes.io/hostname"' $deploy)"

  echo "== and the datastores are INSIDE it, which is the whole reason it is backed =="
  envval() { y ".spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value" $deploy; }
  mount="$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' $deploy)"
  dburl="$(envval DB_URL)"
  case "$dburl" in
    "$mount"/*) echo "  ok   database inside the backed directory: $dburl" ;;
    *) echo "  FAIL database inside the backed directory: '$dburl' is not under '$mount'"; fail=1 ;;
  esac
  check "redis is in-process" "false" "$(envval REDIS_IS_EXTERNAL)"
  check "ca fallback dir" "/appdata/tailscale" "$(envval CA_TS_FALLBACK_DIR)"

  echo "== the identity is two numbers the image reads, and the pod claims none of its own =="
  check "uid"  "4242" "$(envval PUID)"
  check "gid"  "4242" "$(envval PGID)"
  check "no pod security context" "null" "$(y '.spec.template.spec.securityContext' $deploy)"
  check "runs-as-root is countable" "true" "$(y '.metadata.labels."nixk3s.dev/runs-as-root"' $deploy)"
  check "privileges may not be regained" "false" "$(y '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation' $deploy)"

  echo "== the key that must never change arrives by reference, never as a value =="
  secref() { y ".spec.template.spec.containers[0].env[] | select(.name == \"SECRET_ENCRYPTION_KEY\") | $1" $deploy; }
  check "no literal value" "null"                   "$(secref '.value')"
  check "secret named"     "example-portal-secrets" "$(secref '.valueFrom.secretKeyRef.name')"
  check "key named"        "encryption-key"         "$(secref '.valueFrom.secretKeyRef.key')"

  echo "== the probes: the catalogue aims them, the declaration budgets them, both land =="
  # The two halves are read off ONE object, because the split is only worth something if it
  # reassembles: a page and a port the declaration never wrote, next to numbers the catalogue does
  # not carry. Either half missing renders a probe that passes review and fails at three in the
  # morning.
  check "startup path (catalogue)"      "/"     "$(y '.spec.template.spec.containers[0].startupProbe.httpGet.path' $deploy)"
  # The grammar resolves the port NAME the catalogue records to the number behind it, so this is
  # the same fact as the container port above -- asserted here because a probe pointed at a port
  # nothing listens on is green in review and dead in the cluster.
  check "startup port (catalogue)"      "7575"  "$(y '.spec.template.spec.containers[0].startupProbe.httpGet.port' $deploy)"
  check "startup periodSeconds"         "3"     "$(y '.spec.template.spec.containers[0].startupProbe.periodSeconds' $deploy)"
  check "startup failureThreshold"      "40"    "$(y '.spec.template.spec.containers[0].startupProbe.failureThreshold' $deploy)"
  check "startup timeoutSeconds"        "5"     "$(y '.spec.template.spec.containers[0].startupProbe.timeoutSeconds' $deploy)"
  check "readiness path (catalogue)"    "/"     "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' $deploy)"
  check "readiness periodSeconds"       "5"     "$(y '.spec.template.spec.containers[0].readinessProbe.periodSeconds' $deploy)"
  check "readiness failureThreshold"    "30"    "$(y '.spec.template.spec.containers[0].readinessProbe.failureThreshold' $deploy)"
  # The one the catalogue REFUSES. Its absence is the assertion: a budget cannot conjure it, and a
  # rendered tree is where that promise is either kept or quietly broken.
  check "no liveness probe"             "null"  "$(y '.spec.template.spec.containers[0].livenessProbe' $deploy)"

  echo "== a slot is a position, never an address: nothing in the tree became a number =="
  check "the surface holds a position" "33" "$portalSlot"
  check "service type"    "ClusterIP" "$(y '.spec.type' $svc)"
  check "no pinned IP"    "null"      "$(y '.spec.clusterIP' $svc)"
  check "no nodePort"     "null"      "$(y '.spec.ports[0].nodePort' $svc)"

  echo "== exactly one namespace is anchored, and it is protected from cascade-delete =="
  check "namespaces rendered" "1" "$(find -L $manifests -name 'Namespace-*.yaml' -type f | wc -l)"
  check "which namespace" "example-cockpit" "$(y '.metadata.name' $portal/Namespace-example-cockpit.yaml)"
  check "prune is refused" "Prune=false" "$(y '.metadata.annotations."argocd.argoproj.io/sync-options"' $portal/Namespace-example-cockpit.yaml)"

  echo "== the surface lands in the project the cockpit puts management things in =="
  check "project" "example-management" "$(y '.spec.project' $app)"
  check "adopted in place" "ServerSideApply=true" "$(y '.spec.syncPolicy.syncOptions[0]' $app)"

  if [ "$fail" -ne 0 ]; then
    echo "the rendered tree does not match the cockpit's promises" >&2
    exit 1
  fi
  echo "nixk3s: the rendered cockpit matches every promise asserted here"
  touch $out
''
