#!/usr/bin/env bash
set -euo pipefail
environment="${1:-}"
context="${2:-}"
case "$environment" in dev|prod) ;; *) echo 'Usage: bash deploy.sh dev|prod KUBE_CONTEXT [--dry-run]'; exit 2 ;; esac
[[ -n "$context" ]] || { echo 'An explicit Kubernetes context is required'; exit 2; }
[[ "${3:-}" = '' || "${3:-}" = '--dry-run' ]] || { echo 'Unknown option'; exit 2; }
root="$(cd "$(dirname "$0")" && pwd)"
manifest="$root/$environment.yaml"
namespace="login-demo-$environment"
command -v kubectl >/dev/null
images="$(awk '$1 == "image:" { print $2 }' "$manifest")"
[[ "$(printf '%s\n' "$images" | wc -l | tr -d ' ')" = 2 ]] || { echo 'Expected exactly two images'; exit 1; }
if printf '%s\n' "$images" | grep -Ev '^.+@sha256:[0-9a-f]{64}$' >/dev/null; then
  echo 'Replace both image values with real registry/repository@sha256:<64 hex> references first.'
  exit 1
fi
# Namespace and registry Secret are prerequisites; do not silently choose a cluster.
kubectl --context "$context" get namespace "$namespace" -o name
kubectl --context "$context" -n "$namespace" get secret registry-pull -o name
kubectl --context "$context" apply --dry-run=server -f "$manifest"
if [[ "${3:-}" = '--dry-run' ]]; then exit 0; fi
kubectl --context "$context" apply -f "$manifest"
# ConfigMap subPath mounts need a Pod restart to pick up changes.
kubectl --context "$context" -n "$namespace" rollout restart deployment/frontend
kubectl --context "$context" -n "$namespace" rollout status deployment/backend --timeout=240s
kubectl --context "$context" -n "$namespace" rollout status deployment/frontend --timeout=240s
echo "Deployed $environment. Follow README to verify the login flow."
