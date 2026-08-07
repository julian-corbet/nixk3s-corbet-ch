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
# reach the objects; state arrives from either backing and node-path state says
# it is pinned; secrets are consumed by reference and never by value; a
# scale-to-zero app carries no replica count and its Application ignores that
# field; a created namespace is protected from cascade-delete; and a private
# overlay can still set what the public vocabulary refuses to express.
{ pkgs, lib, env }:

pkgs.runCommand "nixk3s-apps-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
  # Not a manifest, so it cannot be asserted from the tree: the read-only list
  # that makes the escape hatch countable.
  escapeHatchApps = lib.concatStringsSep " " env.config.nixk3s.appPlatform.rawEscapeHatchApps;
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
