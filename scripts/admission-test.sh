#!/usr/bin/env bash
# Prove the admission policy against a cluster that already has Kyverno installed.
# Required env: IMAGE (ghcr.io/<owner>/<repo>/app), SIGNED_DIGEST, UNSIGNED_DIGEST, TAG_REF (a tag of the
# signed image), REPO (owner/repo), GHCR_USER, GHCR_TOKEN.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pass=0
fail=0

step() { echo; echo "== $*"; }
ok() {
  echo "  PASS  $1"
  pass=$((pass + 1))
}
bad() {
  echo "  FAIL  $1"
  fail=$((fail + 1))
}

pod_manifest() { # pod_manifest <name> <image>
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
spec:
  imagePullSecrets:
    - name: ghcr-pull
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $2
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
EOF
}

step "registry credentials (the registry is private, so Kyverno and the kubelet both need them)"
for ns in kyverno default; do
  name=ghcr-pull
  [ "$ns" = "kyverno" ] && name=ghcr-creds
  kubectl -n "$ns" create secret docker-registry "$name" \
    --docker-server=ghcr.io --docker-username="$GHCR_USER" --docker-password="$GHCR_TOKEN"
done

step "apply the policy"
IMAGE_PATH="${IMAGE#ghcr.io/}"
export IMAGE_PATH REPO
envsubst '${IMAGE_PATH} ${REPO}' <"$here/../policy/verify-images.yaml.tmpl" | kubectl apply -f -
for _ in $(seq 1 60); do
  ready="$(kubectl get cpol verify-signed-images -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [ "$ready" = "True" ] && break
  sleep 2
done
if [ "$ready" = "True" ]; then ok "policy is Ready"; else bad "policy never became Ready"; fi

step "signed image (by digest) is admitted"
if pod_manifest signed "$IMAGE@$SIGNED_DIGEST" | kubectl apply -f - 2>&1 | tee /tmp/signed.out; then
  ok "admitted"
else
  bad "signed image was rejected"
  cat /tmp/signed.out
fi
if kubectl wait --for=condition=Ready pod/signed --timeout=120s; then ok "pod became Ready"; else bad "pod did not become Ready"; fi
annotation="$(kubectl get pod signed -o jsonpath='{.metadata.annotations.kyverno\.io/verify-images}' 2>/dev/null || true)"
echo "  verify-images annotation: $annotation"
if grep -q pass <<<"$annotation"; then ok "Kyverno recorded a passing verification"; else bad "no passing verification annotation"; fi

step "unsigned image (same repository, no signature) is rejected"
if pod_manifest unsigned "$IMAGE@$UNSIGNED_DIGEST" | kubectl apply -f - >/tmp/unsigned.out 2>&1; then
  bad "unsigned image was admitted"
  kubectl delete pod unsigned --ignore-not-found
else
  ok "rejected"
fi
sed 's/^/        | /' /tmp/unsigned.out
if grep -Eqi 'verif|signature' /tmp/unsigned.out; then ok "rejection message is about image verification"; else bad "rejection was for some other reason"; fi

step "signed image referenced by TAG is admitted and pinned to its digest"
pod_manifest by-tag "$TAG_REF" | kubectl apply -f - || true
resolved="$(kubectl get pod by-tag -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true)"
echo "  resolved image: $resolved"
if [ "$resolved" = "$IMAGE@$SIGNED_DIGEST" ]; then ok "tag was rewritten to the verified digest"; else bad "tag was not pinned to the signed digest"; fi

step "an image outside the policy's scope is not affected"
if pod_manifest outside nginxinc/nginx-unprivileged:1.27-alpine | kubectl apply -f -; then ok "admitted"; else bad "out-of-scope image was blocked"; fi

echo
echo "checks passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
