# Reads the consumer factory's promises back off the RENDERED BYTES.
#
# The factory is now the most load-bearing code in this family: fourteen repositories' worth of
# translator collapsed into one function, so a mistake here is a mistake in every catalogue at
# once. What makes it risky is precisely what makes it possible -- it TOLERATES two spellings of
# `ports`, two of `state`, and two ways of naming the probes a piece of software warrants, and it
# reads five catalogue fields through defaults. Every one of those tolerances is a claim about
# catalogues this repository has never seen.
#
# So the assertions below are about the SPLIT and the TOLERANCES, not about today's output:
#
#   * an integer port and an attrset port both reach a Service, and the attrset's extra field
#     survives -- normalising is not flattening;
#   * a string mount path and an attrset mount path both reach a volumeMount, and a readOnly the
#     CATALOGUE states reaches it without any declaration having said so;
#   * `probes = { readiness = ...; }` and a bare `readiness = ...` produce the same object;
#   * a budget stated by a declaration overrides ONE number and leaves the catalogue's others;
#   * the catalogue names a credential VARIABLE and the declaration names the Secret and key, and
#     what lands in the manifest is a reference rather than a value;
#   * hardening classes reach a securityContext when stamped, and a catalogue that states none
#     renders no securityContext rather than throwing;
#   * a catalogue that omits env, args and credentials renders a working object anyway;
#   * with `origin` unset, nothing grows an address.
{ pkgs, lib, env }:

pkgs.runCommand "nixk3s-consumer-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
} ''
  set -euo pipefail
  fail=0
  check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "  ok   $1: $3"
    else echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
  }
  y() { yq -r "$1" "$2"; }

  one="$manifests/one"
  two="$manifests/two"

  echo "== both spellings of a port reach a Service, and the attrset keeps what only it can say =="
  check "integer port -> containerPort" "8080" \
    "$(y '.spec.template.spec.containers[0].ports[0].containerPort' "$one/Deployment-one.yaml")"
  check "integer port -> service port" "8080" \
    "$(y '.spec.ports[0].port' "$one/Service-one.yaml")"
  check "attrset port -> containerPort" "9000" \
    "$(y '.spec.template.spec.containers[0].ports[0].containerPort' "$two/Deployment-two.yaml")"
  check "attrset port keeps protocol" "TCP" \
    "$(y '.spec.template.spec.containers[0].ports[0].protocol' "$two/Deployment-two.yaml")"

  echo "== both spellings of a directory reach a volumeMount =="
  check "string state -> mountPath" "/var/lib/alpha" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' "$one/Deployment-one.yaml")"
  check "attrset state -> mountPath" "/srv/reference" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' "$two/Deployment-two.yaml")"

  echo "== a readOnly the CATALOGUE states reaches the mount with no declaration saying so =="
  check "catalogue readOnly wins" "true" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[0].readOnly' "$two/Deployment-two.yaml")"

  echo "== the backing the declaration chose is the one that renders =="
  check "node path backing" "/example/state/one" \
    "$(y '.spec.template.spec.volumes[0].hostPath.path' "$one/Deployment-one.yaml")"
  check "node path type" "DirectoryOrCreate" \
    "$(y '.spec.template.spec.volumes[0].hostPath.type' "$one/Deployment-one.yaml")"
  check "claim backing" "example-reference" \
    "$(y '.spec.template.spec.volumes[0].persistentVolumeClaim.claimName' "$two/Deployment-two.yaml")"

  echo "== both spellings of a probe produce the same object =="
  check "probes-attrset readiness path" "/healthz" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' "$one/Deployment-one.yaml")"
  check "per-kind readiness path" "/ready" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' "$two/Deployment-two.yaml")"
  check "per-kind liveness path" "/alive" \
    "$(y '.spec.template.spec.containers[0].livenessProbe.httpGet.path' "$two/Deployment-two.yaml")"

  echo "== a budget overrides ONE number; the catalogue keeps the rest =="
  check "declared failureThreshold" "30" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.failureThreshold' "$one/Deployment-one.yaml")"
  check "catalogued periodSeconds survives" "10" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.periodSeconds' "$one/Deployment-one.yaml")"
  check "catalogued timeoutSeconds survives" "1" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.timeoutSeconds' "$one/Deployment-one.yaml")"

  echo "== a credential arrives as a REFERENCE, under the key the declaration renamed =="
  check "credential secret name" "example-one-credentials" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name=="ALPHA_TOKEN") | .valueFrom.secretKeyRef.name' "$one/Deployment-one.yaml")"
  check "credential key renamed" "token" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name=="ALPHA_TOKEN") | .valueFrom.secretKeyRef.key' "$one/Deployment-one.yaml")"
  # A REFERENCE means the variable carries no inline `value` at all. Grepping the tree for a
  # literal nothing defines would have been tautological -- this reads the field that would hold a
  # secret if the factory ever inlined one.
  check "credential carries no inline value" "null" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name=="ALPHA_TOKEN") | .value' "$one/Deployment-one.yaml")"

  echo "== a second credential comes from a DIFFERENT Secret, grouped per Secret =="
  check "per-variable secret override" "example-shared-mail" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name=="ALPHA_SMTP_PASSWORD") | .valueFrom.secretKeyRef.name' "$one/Deployment-one.yaml")"
  check "its key defaults to the variable name" "ALPHA_SMTP_PASSWORD" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name=="ALPHA_SMTP_PASSWORD") | .valueFrom.secretKeyRef.key' "$one/Deployment-one.yaml")"
  check "the default Secret still delivers the other" "example-one-credentials" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name=="ALPHA_TOKEN") | .valueFrom.secretKeyRef.name' "$one/Deployment-one.yaml")"

  echo "== a declaration's env wins over the catalogue's, and args append =="
  check "env merged over catalogue" "declared" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name=="ALPHA_MODE") | .value' "$one/Deployment-one.yaml")"
  check "catalogue arg first" "--serve" \
    "$(y '.spec.template.spec.containers[0].args[0]' "$one/Deployment-one.yaml")"
  check "declared arg appended" "--verbose" \
    "$(y '.spec.template.spec.containers[0].args[1]' "$one/Deployment-one.yaml")"

  echo "== hardening classes reach a securityContext when stamped =="
  check "capabilities dropped" "ALL" \
    "$(y '.spec.template.spec.containers[0].securityContext.capabilities.drop[0]' "$one/Deployment-one.yaml")"
  check "escalation refused" "false" \
    "$(y '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation' "$one/Deployment-one.yaml")"
  check "root filesystem read-only" "true" \
    "$(y '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' "$one/Deployment-one.yaml")"
  check "seccomp on the pod" "RuntimeDefault" \
    "$(y '.spec.template.spec.securityContext.seccompProfile.type' "$one/Deployment-one.yaml")"

  echo "== a catalogue that states NO hardening renders none, rather than throwing =="
  check "no container securityContext" "null" \
    "$(y '.spec.template.spec.containers[0].securityContext' "$two/Deployment-two.yaml")"

  echo "== a catalogue that omits env, args and credentials still renders =="
  check "no env at all" "null" \
    "$(y '.spec.template.spec.containers[0].env' "$two/Deployment-two.yaml")"
  check "no args at all" "null" \
    "$(y '.spec.template.spec.containers[0].args' "$two/Deployment-two.yaml")"

  echo "== the image is the catalogue repository plus the declaration's version =="
  check "image built from version" "registry.example.com/example-org/alpha:1.4.2" \
    "$(y '.spec.template.spec.containers[0].image' "$one/Deployment-one.yaml")"

  echo "== with origin unset, nothing grew an address =="
  check "no pinned clusterIP" "null" \
    "$(y '.spec.clusterIP' "$one/Service-one.yaml")"

  if [ "$fail" -ne 0 ]; then echo "nixk3s consumer-render FAILED"; exit 1; fi
  echo "nixk3s: the consumer factory renders what it promises"
  touch $out
''
