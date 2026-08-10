# Asserts what `nixk3s.apps` actually RENDERS, by reading the manifests out of
# the rendered environment with a YAML parser.
#
# Why not just evaluate: a module that type-checks can still render a broken
# Deployment — a selector that does not match its own pod template, a Service
# pointing at a port name nothing declares, a replica count baked into a
# manifest that an autoscaler owns. None of that is an eval error, all of it is
# an outage. So this check parses the rendered YAML and asserts field by field.
#
# The assertions below are the module's PROMISES, not a transcript of its
# current output: an app renders a Deployment and a Service; exposure/scaling
# reach the objects; state arrives from any of its five backings and node-path
# state says it is pinned; secrets are consumed by reference, never by value,
# and only by the containers named; a pod may hold several containers, with the
# app's own keeping its own name and init containers keeping their written
# order; a port may be real and unpublished; an identity is a role here and a
# number at the site; a scale-to-zero app carries no replica count and its
# Application ignores that field; a created namespace is protected from
# cascade-delete; and a private overlay can still set what the public vocabulary
# refuses to express.
{ pkgs, lib, env }:

pkgs.runCommand "nixk3s-apps-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
  # Not a manifest, so it cannot be asserted from the tree: the read-only list
  # that makes the escape hatch countable.
  escapeHatchApps = lib.concatStringsSep " " env.config.nixk3s.appPlatform.rawEscapeHatchApps;
  # The same, for the surface this grammar will be judged on: how many apps
  # actually wanted more than one container.
  multiContainerApps = lib.concatStringsSep " " env.config.nixk3s.appPlatform.multiContainerApps;
  # Also not a manifest: the band model governs a number and renders nothing
  # from it, so the only way to see it work in the rendered tree is that the
  # private overlay turned the slot into an address (asserted below).
  webSlot = toString env.config.nixk3s.apps.example-web.slot;
} ''
  set -euo pipefail
  fail=0

  # check <what> <expected> <actual>
  check() {
    if [ "$2" = "$3" ]; then
      echo "  ok   $1: $3"
    else
      echo "  FAIL $1: expected '$2', got '$3'"
      fail=1
    fi
  }

  present() {
    if [ -e "$2" ]; then
      echo "  ok   $1: rendered"
    else
      echo "  FAIL $1: not rendered ($2)"
      fail=1
    fi
  }

  absent() {
    if [ -e "$2" ]; then
      echo "  FAIL $1: rendered but should not be ($2)"
      fail=1
    else
      echo "  ok   $1: correctly not rendered"
    fi
  }

  y() { yq -r "$1" "$2"; }

  WEB_D=$manifests/example-web/Deployment-example-web.yaml
  WEB_S=$manifests/example-web/Service-example-web.yaml
  WEB_A=$manifests/apps/Application-example-web.yaml
  CANVAS_D=$manifests/example-canvas/Deployment-example-canvas.yaml
  CANVAS_A=$manifests/apps/Application-example-canvas.yaml
  WORKER_D=$manifests/example-worker/Deployment-example-worker.yaml
  WORKER_NS=$manifests/example-worker/Namespace-example-worker.yaml
  PORTAL_D=$manifests/example-portal/Deployment-example-portal.yaml
  PORTAL_S=$manifests/example-portal/Service-example-portal.yaml
  RELAY_D=$manifests/example-relay/Deployment-example-relay.yaml

  # Containers are keyed by name and emitted in attribute order, so a lookup by
  # name is the only honest way to assert on one of several.
  c()  { yq -r ".spec.template.spec.containers[] | select(.name == \"$1\") | $2" "$3"; }
  # ... and a count, for asserting that something is NOT there. An empty yq
  # selection prints nothing, which is indistinguishable from a field that is
  # present and empty; a length is a number either way.
  cn() { yq -r "[.spec.template.spec.containers[] | select(.name == \"$1\") | $2] | length" "$3"; }

  echo "== the whole rendered Deployment of an always-on, exposed app =="
  cat $WEB_D

  echo "== a minimal app renders a Deployment AND a Service =="
  present "Deployment" "$WEB_D"
  present "Service" "$WEB_S"
  check "Deployment kind"      "Deployment" "$(y '.kind' $WEB_D)"
  check "Deployment apiVersion" "apps/v1"   "$(y '.apiVersion' $WEB_D)"
  check "Service kind"         "Service"    "$(y '.kind' $WEB_S)"
  check "namespace"            "example-apps" "$(y '.metadata.namespace' $WEB_D)"
  check "image"                "registry.example.com/example-org/example-web:1.4.2@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
                               "$(y '.spec.template.spec.containers[0].image' $WEB_D)"
  check "container port"       "8080"       "$(y '.spec.template.spec.containers[0].ports[0].containerPort' $WEB_D)"
  check "container port name"  "http"       "$(y '.spec.template.spec.containers[0].ports[0].name' $WEB_D)"
  check "plain env value"      "0.0.0.0"    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "EXAMPLE_BIND_ADDRESS") | .value' $WEB_D)"

  echo "== the selector matches the pod template it selects =="
  check "selector"   "example-web" "$(y '.spec.selector.matchLabels."app.kubernetes.io/name"' $WEB_D)"
  check "pod label"  "example-web" "$(y '.spec.template.metadata.labels."app.kubernetes.io/name"' $WEB_D)"
  check "svc selector" "example-web" "$(y '.spec.selector."app.kubernetes.io/name"' $WEB_S)"

  echo "== the Service targets a port the container actually declares =="
  check "service port"       "8080" "$(y '.spec.ports[0].port' $WEB_S)"
  check "service targetPort" "http" "$(y '.spec.ports[0].targetPort' $WEB_S)"

  echo "== exposure is a CLASS on the objects, never an address =="
  check "deployment exposure" "public"    "$(y '.metadata.labels."nixk3s.dev/exposure"' $WEB_D)"
  check "service exposure"    "public"    "$(y '.metadata.labels."nixk3s.dev/exposure"' $WEB_S)"
  check "service type"        "ClusterIP" "$(y '.spec.type' $WEB_S)"
  check "no loadBalancerIP"   "null"      "$(y '.spec.loadBalancerIP' $WEB_S)"
  check "no external IPs"     "null"      "$(y '.spec.externalIPs' $WEB_S)"
  check "no nodePort"         "null"      "$(y '.spec.ports[0].nodePort' $WEB_S)"
  check "internal app class"  "internal"  "$(y '.metadata.labels."nixk3s.dev/exposure"' $WORKER_D)"
  check "overlay app class"   "nb"        "$(y '.metadata.labels."nixk3s.dev/exposure"' $CANVAS_D)"

  echo "== scaling reaches the objects, and scale-to-zero surrenders the replica count =="
  check "always: label"          "always"        "$(y '.metadata.labels."nixk3s.dev/scaling"' $WEB_D)"
  check "always: replicas"       "2"             "$(y '.spec.replicas' $WEB_D)"
  check "always: no wake label"  "null"          "$(y '.metadata.labels."nixk3s.dev/wake"' $WEB_D)"
  check "s2z: label"             "scale-to-zero" "$(y '.metadata.labels."nixk3s.dev/scaling"' $CANVAS_D)"
  check "s2z: no replicas"       "null"          "$(y '.spec.replicas' $CANVAS_D)"
  check "s2z: ignoreDifferences" "/spec/replicas" "$(y '.spec.ignoreDifferences[0].jsonPointers[0]' $CANVAS_A)"
  check "s2z: ignored kind"      "Deployment"    "$(y '.spec.ignoreDifferences[0].kind' $CANVAS_A)"
  check "always: nothing ignored" "null"         "$(y '.spec.ignoreDifferences' $WEB_A)"

  echo "== probes: readiness and liveness as declared, never synthesized =="
  check "readiness path"      "/healthz" "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' $WEB_D)"
  check "readiness delay"     "10"       "$(y '.spec.template.spec.containers[0].readinessProbe.initialDelaySeconds' $WEB_D)"
  check "liveness period"     "30"       "$(y '.spec.template.spec.containers[0].livenessProbe.periodSeconds' $WEB_D)"
  check "liveness threshold"  "6"        "$(y '.spec.template.spec.containers[0].livenessProbe.failureThreshold' $WEB_D)"
  check "no startup probe"    "null"     "$(y '.spec.template.spec.containers[0].startupProbe' $WEB_D)"
  check "undeclared app: no probes at all" "null" "$(y '.spec.template.spec.containers[0].readinessProbe' $WORKER_D)"

  echo "== resources are sized where declared, and only there =="
  check "cpu request"    "50m"   "$(y '.spec.template.spec.containers[0].resources.requests.cpu' $WEB_D)"
  check "memory limit"   "256Mi" "$(y '.spec.template.spec.containers[0].resources.limits.memory' $WEB_D)"
  check "unsized app"    "null"  "$(y '.spec.template.spec.containers[0].resources' $WORKER_D)"

  echo "== secrets are consumed BY REFERENCE — never a value in the tree =="
  check "secretKeyRef name" "credentials" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "EXAMPLE_DB_PASSWORD") | .valueFrom.secretKeyRef.name' $WEB_D)"
  check "secretKeyRef key"  "db-password" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "EXAMPLE_DB_PASSWORD") | .valueFrom.secretKeyRef.key' $WEB_D)"
  check "envFrom secretRef" "example-web-oidc" \
    "$(y '.spec.template.spec.containers[0].envFrom[0].secretRef.name' $WEB_D)"
  check "no literal secret value" "null" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "EXAMPLE_DB_PASSWORD") | .value' $WEB_D)"
  check "mounted secret volume" "example-worker-credentials" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "secret-credentials") | .secret.secretName' $WORKER_D)"
  check "mounted secret is read-only" "true" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "secret-credentials") | .readOnly' $WORKER_D)"
  absent "a rendered Secret object" "$manifests/example-worker/Secret-example-worker-credentials.yaml"

  echo "== state: one concept, two backings =="
  check "claim backing"  "example-canvas-config" \
    "$(y '.spec.template.spec.volumes[0].persistentVolumeClaim.claimName' $CANVAS_D)"
  check "claim mount"    "/config"    "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' $CANVAS_D)"
  check "hostPath backing" "/example/spool/example-worker" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "spool") | .hostPath.path' $WORKER_D)"
  check "hostPath type"  "Directory" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "spool") | .hostPath.type' $WORKER_D)"
  check "hostPath mount" "/var/spool/example" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "spool") | .mountPath' $WORKER_D)"
  check "state forces Recreate"  "Recreate"      "$(y '.spec.strategy.type' $CANVAS_D)"
  check "stateless rolls"        "RollingUpdate" "$(y '.spec.strategy.type' $WEB_D)"
  absent "PersistentVolumeClaim" "$manifests/example-canvas/PersistentVolumeClaim-example-canvas-config.yaml"

  echo "== node-path state admits that it pins the pod =="
  check "node-pinned label"  "true" "$(y '.metadata.labels."nixk3s.dev/node-pinned"' $WORKER_D)"
  check "nodeSelector"       "example-node" \
    "$(y '.spec.template.spec.nodeSelector."kubernetes.io/hostname"' $WORKER_D)"
  check "claim-backed app is not pinned" "null" "$(y '.metadata.labels."nixk3s.dev/node-pinned"' $CANVAS_D)"
  check "claim-backed app has no nodeSelector" "null" "$(y '.spec.template.spec.nodeSelector' $CANVAS_D)"

  echo "== a GPU app gets the device, the sablier front, and Recreate =="
  check "gpu label"     "true"     "$(y '.metadata.labels."nixk3s.dev/gpu"' $CANVAS_D)"
  check "wake front"    "sablier"  "$(y '.metadata.labels."nixk3s.dev/wake"' $CANVAS_D)"
  check "device limit"  "1"        "$(y '.spec.template.spec.containers[0].resources.limits."example.com/gpu"' $CANVAS_D)"
  check "device request" "1"       "$(y '.spec.template.spec.containers[0].resources.requests."example.com/gpu"' $CANVAS_D)"

  echo "== a portless app renders no Service =="
  present "worker Deployment" "$WORKER_D"
  absent  "worker Service"    "$manifests/example-worker/Service-example-worker.yaml"
  check "worker args" "--queue" "$(y '.spec.template.spec.containers[0].args[0]' $WORKER_D)"

  echo "== the whole rendered Deployment of a multi-container app =="
  cat $PORTAL_D

  echo "== a companion runs BESIDE the app's own container, which keeps its own name =="
  check "two containers"    "2" "$(y '.spec.template.spec.containers | length' $PORTAL_D)"
  # THE INVARIANT EVERY PRIVATE OVERLAY DEPENDS ON: the app's own container is
  # keyed by the app's name, so `...containers.<app>...` keeps landing on it no
  # matter how many neighbours it grows.
  check "the app's container is named for the app" "example-portal" \
    "$(y '.spec.template.spec.containers[] | select(.image | contains("example-portal")) | .name' $PORTAL_D)"
  check "the companion is named for its key" "example-front" \
    "$(c web '.image | split(":")[0] | split("/")[-1]' $PORTAL_D)"
  check "the companion carries its own resources" "32Mi" "$(c web '.resources.requests.memory' $PORTAL_D)"
  check "and its own probe"  "/healthz" "$(c web '.readinessProbe.httpGet.path' $PORTAL_D)"
  check "resolved against ITS OWN port table" "8080" "$(c web '.readinessProbe.httpGet.port' $PORTAL_D)"
  check "the app's container has no probe of its own" "0" \
    "$(cn example-portal '.readinessProbe | select(. != null)' $PORTAL_D)"
  check "the GPU device is never spread across a pod" "null" "$(c web '.resources.limits."example.com/gpu"' $PORTAL_D)"
  check "a single-container app still renders one" "1" "$(y '.spec.template.spec.containers | length' $WEB_D)"

  echo "== init containers run IN THE ORDER WRITTEN, not in attribute order =="
  check "first init"  "prepare-tree"   "$(y '.spec.template.spec.initContainers[0].name' $PORTAL_D)"
  check "second init" "assert-secrets" "$(y '.spec.template.spec.initContainers[1].name' $PORTAL_D)"
  check "and it mounts a volume the grammar minted" "cfg-secret" \
    "$(y '.spec.template.spec.initContainers[1].volumeMounts[0].name' $PORTAL_D)"
  # THE CHECK THAT KEEPS THE ONE ABOVE HONEST. An attribute-keyed render sorts
  # alphabetically, so if these two names ever stop being in REVERSE
  # alphabetical order the order assertions pass for the wrong reason and prove
  # nothing about the mechanism.
  first=$(y '.spec.template.spec.initContainers[0].name' $PORTAL_D)
  second=$(y '.spec.template.spec.initContainers[1].name' $PORTAL_D)
  if [ "$first" \< "$second" ]; then
    echo "  FAIL init-order case is vacuous: '$first' sorts before '$second', so an attribute-keyed"
    echo "       render would pass too. Rename one so the written order is not the alphabetical one."
    fail=1
  else
    echo "  ok   init order is genuinely non-alphabetical: '$first' then '$second'"
  fi
  # nixidy drops a null field but renders an empty list, so this must be ABSENT
  # rather than empty on the apps that declare none.
  check "no initContainers key on an app with none" "null" \
    "$(y '.spec.template.spec.initContainers' $WEB_D)"

  echo "== a port can be REAL and unpublished =="
  check "unpublished port is on the container" "9000" "$(c example-portal '.ports[0].containerPort' $PORTAL_D)"
  check "under its own name"                   "app"  "$(c example-portal '.ports[0].name' $PORTAL_D)"
  check "the Service carries exactly one port"  "1"   "$(y '.spec.ports | length' $PORTAL_S)"
  check "and it is the companion's"          "http"  "$(y '.spec.ports[0].name' $PORTAL_S)"
  check "published on the port asked for"    "80"    "$(y '.spec.ports[0].port' $PORTAL_S)"
  check "targeted by NAME, which resolves pod-wide" "http" "$(y '.spec.ports[0].targetPort' $PORTAL_S)"
  check "the unpublished port never reaches the Service" "0" \
    "$(y '[.spec.ports[] | select(.name == "app")] | length' $PORTAL_S)"
  # THE WHOLE SELECTOR ARGUMENT, checked rather than asserted in prose: pointing
  # a Service at a companion changes no selector, because a selector selects
  # PODS and every container is inside the pod.
  check "the selector is untouched by any of it" "example-portal" \
    "$(y '.spec.selector."app.kubernetes.io/name"' $PORTAL_S)"
  check "and matches the pod template it selects" "example-portal" \
    "$(y '.spec.template.metadata.labels."app.kubernetes.io/name"' $PORTAL_D)"

  echo "== an app that publishes NOTHING renders no Service, exactly like a portless one =="
  present "relay Deployment" "$RELAY_D"
  absent  "relay Service"    "$manifests/example-relay/Service-example-relay.yaml"
  check "the port is still on the container" "9100" "$(c example-relay '.ports[0].containerPort' $RELAY_D)"
  check "and its probe still resolves"       "9100" "$(c example-relay '.readinessProbe.tcpSocket.port' $RELAY_D)"

  echo "== a Secret reaches the containers NAMED, and no others =="
  check "the app's own credential lands on the app" "credentials" \
    "$(c example-portal '.env[] | select(.name == "EXAMPLE_DB_PASSWORD") | .valueFrom.secretKeyRef.name' $PORTAL_D)"
  check "the front does not hold it"                "0" \
    "$(cn web '.env[] | select(.name == "EXAMPLE_DB_PASSWORD")' $PORTAL_D)"
  check "the front's own token lands on the front"  "example-portal-front-token" \
    "$(c web '.env[] | select(.name == "EXAMPLE_FRONT_TOKEN") | .valueFrom.secretKeyRef.name' $PORTAL_D)"
  check "and the app does not hold that"            "0" \
    "$(cn example-portal '.env[] | select(.name == "EXAMPLE_FRONT_TOKEN")' $PORTAL_D)"

  echo "== five backings, one `state` noun, and none of the objects created here =="
  check "configMap backing" "example-portal-web" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "web-conf") | .configMap.name' $PORTAL_D)"
  check "secret backing"    "example-portal-secrets" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "cfg-secret") | .secret.secretName' $PORTAL_D)"
  check "scratch backing"   "true" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "scratch") | .emptyDir != null' $PORTAL_D)"
  absent "a rendered ConfigMap" "$manifests/example-portal/ConfigMap-example-portal-web.yaml"
  absent "a rendered Secret"    "$manifests/example-portal/Secret-example-portal-secrets.yaml"
  check "only the key asked for is projected" "1" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "cfg-secret") | .secret.items | length' $PORTAL_D)"
  check "projected key"  "zzz-secrets.conf" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "cfg-secret") | .secret.items[0].key' $PORTAL_D)"
  check "projected path" "zzz-secrets.conf" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "cfg-secret") | .secret.items[0].path' $PORTAL_D)"
  check "no items where the backing has no keys" "null" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "html") | .hostPath.items' $PORTAL_D)"
  check "a non-durable backing does not pin the pod" "null" \
    "$(y '.metadata.labels."nixk3s.dev/node-pinned"' $RELAY_D)"

  echo "== a volume is declared ONCE and mounted wherever it is needed =="
  check "the app has two views of one volume" "2" "$(cn example-portal '.volumeMounts[] | select(.name == "html")' $PORTAL_D)"
  check "the second is a subPath"        "config" \
    "$(c example-portal '.volumeMounts[] | select(.mountPath == "/var/www/config") | .subPath' $PORTAL_D)"
  check "the front's view is read-only"  "true" \
    "$(c web '.volumeMounts[] | select(.name == "html") | .readOnly' $PORTAL_D)"
  check "the app's own view is not"      "null" \
    "$(c example-portal '.volumeMounts[] | select(.mountPath == "/var/www/html") | .readOnly' $PORTAL_D)"
  check "an init container gets its own view too" "/var/www/html" \
    "$(y '.spec.template.spec.initContainers[0].volumeMounts[0].mountPath' $PORTAL_D)"
  # The volume nothing but the front reads — legal only because a `state` entry
  # may give neither `mountPath` nor `mounts`.
  check "a volume only the companion reads still renders" "1" \
    "$(y '[.spec.template.spec.volumes[] | select(.name == "web-conf")] | length' $PORTAL_D)"
  check "and only the companion mounts it" "0" "$(cn example-portal '.volumeMounts[] | select(.name == "web-conf")' $PORTAL_D)"
  check "the mount key is the volume name" "html" \
    "$(c example-portal '.volumeMounts[] | select(.mountPath == "/var/www/html") | .name' $PORTAL_D)"

  echo "== an identity is a ROLE on the app and a NUMBER at the site =="
  check "pod runAsUser"   "4242" "$(y '.spec.template.spec.securityContext.runAsUser' $PORTAL_D)"
  check "pod runAsGroup"  "4242" "$(y '.spec.template.spec.securityContext.runAsGroup' $PORTAL_D)"
  check "runAsNonRoot"    "true" "$(y '.spec.template.spec.securityContext.runAsNonRoot' $PORTAL_D)"
  check "seccomp profile" "RuntimeDefault" "$(y '.spec.template.spec.securityContext.seccompProfile.type' $PORTAL_D)"
  # fsGroup is a RECURSIVE CHOWN on every pod start, so it is rendered only
  # where a volume asked for it — and `example-worker`, which is node-path
  # backed and asked for nothing, is the proof that it is not derived.
  check "fsGroup, because a volume asked" "4242" "$(y '.spec.template.spec.securityContext.fsGroup' $PORTAL_D)"
  check "no securityContext where nothing asked" "null" "$(y '.spec.template.spec.securityContext' $WORKER_D)"
  check "container hardening on the app's own container" "false" \
    "$(c example-portal '.securityContext.allowPrivilegeEscalation' $PORTAL_D)"
  check "dropped capability" "ALL" "$(c example-portal '.securityContext.capabilities.drop[0]' $PORTAL_D)"
  check "the companion carries only what IT declared" "null" "$(c web '.securityContext.capabilities' $PORTAL_D)"
  check "no uid on any container of the pod" "0" \
    "$(y '[.spec.template.spec.containers[] | .securityContext.runAsUser | select(. != null)] | length' $PORTAL_D)"

  echo "== the other spelling: the numbers arrive as environment, and no uid is rendered =="
  check "uid as environment" "4343" "$(c example-relay '.env[] | select(.name == "EXAMPLE_UID") | .value' $RELAY_D)"
  check "gid as environment" "4343" "$(c example-relay '.env[] | select(.name == "EXAMPLE_GID") | .value' $RELAY_D)"
  check "and no securityContext at all" "null" "$(y '.spec.template.spec.securityContext' $RELAY_D)"

  echo "== `singleWriter` says the property the volume was only a proxy for =="
  check "no durable state" "null"     "$(y '.spec.template.spec.volumes' $RELAY_D)"
  check "and still Recreate" "Recreate" "$(y '.spec.strategy.type' $RELAY_D)"

  echo "== a namespace this grammar creates cannot be cascade-deleted =="
  present "Namespace" "$WORKER_NS"
  check "Prune=false" "Prune=false" "$(y '.metadata.annotations."argocd.argoproj.io/sync-options"' $WORKER_NS)"

  echo "== adoption asks for server-side apply and diff =="
  check "adopt: SSA"       "ServerSideApply=true"  "$(y '.spec.syncPolicy.syncOptions[0]' $CANVAS_A)"
  check "adopt: SSD"       "ServerSideDiff=true"   "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $CANVAS_A)"
  check "no adopt: no SSA" "null"                  "$(y '.spec.syncPolicy.syncOptions' $WEB_A)"
  check "no adopt: no SSD" "null"                  "$(y '.metadata.annotations' $WEB_A)"

  echo "== the escape hatch passes whole objects through, visibly =="
  present "raw ConfigMap" "$manifests/example-canvas/ConfigMap-example-canvas-extra.yaml"
  check "raw kind" "ConfigMap" "$(y '.kind' $manifests/example-canvas/ConfigMap-example-canvas-extra.yaml)"
  check "raw content untouched" "# an object this grammar has no term for" \
    "$(y '.data."example.conf"' $manifests/example-canvas/ConfigMap-example-canvas-extra.yaml | head -1)"
  check "escape hatch is countable" "example-canvas" "$escapeHatchApps"

  echo "== and so is the surface this multi-container vocabulary will be judged on =="
  check "multi-container apps are countable" "example-portal" "$multiContainerApps"

  echo "== a private overlay sets what the public vocabulary refuses to express =="
  # Derived from the app's SLOT, which is the point: the public side declares
  # one number inside its repository's band, the private side decides what that
  # number means. Nothing in the rendered tree comes from the band model itself.
  check "pinned clusterIP"      "10.0.0.$webSlot" "$(y '.spec.clusterIP' $WEB_S)"
  check "still the grammar's Service" "public" "$(y '.metadata.labels."nixk3s.dev/exposure"' $WEB_S)"
  check "still ClusterIP"       "ClusterIP" "$(y '.spec.type' $WEB_S)"
  check "pod-spec knob"         "false"     "$(y '.spec.template.spec.enableServiceLinks' $WEB_D)"
  check "private UID"           "3001"      "$(y '.spec.template.spec.securityContext.runAsUser' $WEB_D)"
  check "overlay kept the grammar's container" "example-web" \
    "$(y '.spec.template.spec.containers[0].name' $WEB_D)"

  echo "== every app's Application lands in its project =="
  check "web project"    "apps"     "$(y '.spec.project' $WEB_A)"
  check "canvas project" "advanced" "$(y '.spec.project' $CANVAS_A)"
  check "canvas destination" "example-gpu" "$(y '.spec.destination.namespace' $CANVAS_A)"

  echo "== and the tenancy model lists every destination those apps use =="
  for pair in "apps:example-apps" "apps:example-worker" "advanced:example-gpu"; do
    proj=''${pair%%:*}; ns=''${pair##*:}
    check "AppProject $proj allows $ns" "$ns" \
      "$(yq -r ".spec.destinations[] | select(.namespace == \"$ns\") | .namespace" $manifests/projects/AppProject-$proj.yaml)"
  done

  if [ "$fail" -ne 0 ]; then
    echo "rendered output does not match the grammar's promises" >&2
    exit 1
  fi
  echo "all render assertions hold"
  cp -r $manifests $out
''
