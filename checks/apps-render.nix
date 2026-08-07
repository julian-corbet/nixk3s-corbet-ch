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
# reach the objects; a scale-to-zero app carries no replica count and its
# Application ignores that field; a portless app renders no Service; a created
# namespace is protected from cascade-delete.
{ pkgs, environmentPackage }:

pkgs.runCommand "nixk3s-apps-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = environmentPackage;
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
  check "env value"            "0.0.0.0"    "$(y '.spec.template.spec.containers[0].env[0].value' $WEB_D)"
  check "readiness path"       "/healthz"   "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' $WEB_D)"
  check "no liveness probe"    "null"       "$(y '.spec.template.spec.containers[0].livenessProbe' $WEB_D)"

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
  check "always: nothing ignored" "null"         "$(y '.spec.ignoreDifferences' $manifests/apps/Application-example-web.yaml)"

  echo "== a GPU app gets the device, the sablier front, and Recreate =="
  check "gpu label"     "true"     "$(y '.metadata.labels."nixk3s.dev/gpu"' $CANVAS_D)"
  check "wake front"    "sablier"  "$(y '.metadata.labels."nixk3s.dev/wake"' $CANVAS_D)"
  check "device limit"  "1"        "$(y '.spec.template.spec.containers[0].resources.limits."example.com/gpu"' $CANVAS_D)"
  check "device request" "1"       "$(y '.spec.template.spec.containers[0].resources.requests."example.com/gpu"' $CANVAS_D)"

  echo "== state mounts an EXISTING claim by name, and forces Recreate =="
  check "claim name"  "example-canvas-config" "$(y '.spec.template.spec.volumes[0].persistentVolumeClaim.claimName' $CANVAS_D)"
  check "mount path"  "/config"    "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' $CANVAS_D)"
  check "strategy"    "Recreate"   "$(y '.spec.strategy.type' $CANVAS_D)"
  check "stateless strategy" "RollingUpdate" "$(y '.spec.strategy.type' $WEB_D)"
  absent "PersistentVolumeClaim" "$manifests/example-canvas/PersistentVolumeClaim-example-canvas-config.yaml"

  echo "== a portless app renders no Service =="
  present "worker Deployment" "$WORKER_D"
  absent  "worker Service"    "$manifests/example-worker/Service-example-worker.yaml"
  check "worker args" "--queue" "$(y '.spec.template.spec.containers[0].args[0]' $WORKER_D)"

  echo "== a namespace this grammar creates cannot be cascade-deleted =="
  present "Namespace" "$WORKER_NS"
  check "Prune=false" "Prune=false" "$(y '.metadata.annotations."argocd.argoproj.io/sync-options"' $WORKER_NS)"

  echo "== every app's Application lands in its project =="
  check "web project"    "apps"     "$(y '.spec.project' $manifests/apps/Application-example-web.yaml)"
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
