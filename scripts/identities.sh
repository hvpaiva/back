#!/usr/bin/env bash
# The lab's identities: each gets a kubectl context, with a certificate signed by the cluster's CA
# that names its user and group, and an Argo CD password. In a company, an identity provider would
# supply both.
#
#   scripts/identities.sh          issue what's missing (just identities)
#   scripts/identities.sh check    check that each context authenticates, in its group
#   scripts/identities.sh remove   remove the contexts from the lab's kubeconfig (just down)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

identities=(dev:team-a platform-admin:platform) # user:group
days=30

authenticates() { # user group
  kubectl --context "$1" auth whoami --output json 2>/dev/null |
    jq -e --arg group "$2" '.status.userInfo.groups | index($group)' >/dev/null
}

issue_certificate() { # user group
  local user=$1 group=$2 certificate=""
  openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$user/O=$group" \
    -keyout "$work/$user.key" -out "$work/$user.csr" 2>/dev/null
  kubectl delete certificatesigningrequest "$user" --ignore-not-found >/dev/null
  jq -n --arg user "$user" --arg request "$(base64 <"$work/$user.csr" | tr -d '\n')" --argjson seconds $((days * 86400)) '{
    apiVersion: "certificates.k8s.io/v1", kind: "CertificateSigningRequest", metadata: {name: $user},
    spec: {request: $request, signerName: "kubernetes.io/kube-apiserver-client", expirationSeconds: $seconds, usages: ["client auth"]}
  }' | kubectl create --filename - >/dev/null
  kubectl certificate approve "$user" >/dev/null
  for _ in $(seq 30); do
    certificate=$(kubectl get certificatesigningrequest "$user" --output jsonpath='{.status.certificate}')
    [[ -n $certificate ]] && break
    sleep 1
  done
  if [[ -z $certificate ]]; then
    fail "$user: the cluster didn't sign its certificate (kubectl describe csr $user)"
    return 1
  fi
  base64 --decode <<<"$certificate" >"$work/$user.crt"
  kubectl config set-credentials "$user" --embed-certs \
    --client-certificate="$work/$user.crt" --client-key="$work/$user.key" >/dev/null
  kubectl config set-context "$user" --cluster="$cluster" --user="$user" >/dev/null
}

# Argo CD keeps bcrypt hashes in argocd-secret; the passwords stay in the cluster, next to them,
# like the one Argo CD generates for its built-in admin.
set_passwords() {
  local stored hashes identity user password literals=()
  stored=$(kubectl --namespace argocd get secret argocd-account-passwords --output json 2>/dev/null || echo '{}')
  hashes=$(kubectl --namespace argocd get secret argocd-secret --output json)
  for identity in "${identities[@]}"; do
    user=${identity%%:*}
    password=$(jq -r --arg user "$user" '.data[$user] // empty | @base64d' <<<"$stored")
    if [[ -z $password ]] || ! jq -e --arg key "accounts.$user.password" '.data[$key]' <<<"$hashes" >/dev/null; then
      password=${password:-$(openssl rand -hex 12)}
      kubectl --namespace argocd patch secret argocd-secret --type merge --patch "$(jq -n --arg user "$user" \
        --arg hash "$(argocd account bcrypt --password "$password")" --arg now "$(date -u +%FT%TZ)" \
        '{stringData: {"accounts.\($user).password": $hash, "accounts.\($user).passwordMtime": $now}}')" >/dev/null
    fi
    literals+=(--from-literal="$user=$password")
  done
  kubectl --namespace argocd create secret generic argocd-account-passwords "${literals[@]}" \
    --dry-run=client --output yaml | kubectl apply --filename - >/dev/null
}

case ${1:-issue} in
  issue)
    section "Identities"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cluster=$(kubectl config view --minify --output jsonpath='{.contexts[0].context.cluster}')
    for identity in "${identities[@]}"; do
      user=${identity%%:*} group=${identity#*:}
      if ! authenticates "$user" "$group"; then
        issue_certificate "$user" "$group"
      fi
    done
    set_passwords
    for identity in "${identities[@]}"; do
      user=${identity%%:*} group=${identity#*:}
      ok "$user in $group: kubectl --context $user, Argo CD password from just argocd-password $user"
    done
    ;;
  check)
    for identity in "${identities[@]}"; do
      user=${identity%%:*} group=${identity#*:}
      if authenticates "$user" "$group"; then
        ok "identity    $user in $group, kubectl --context $user"
      else
        fail "identity    $user doesn't authenticate as a member of $group"
        hint "just identities"
      fi
    done
    ((problems == 0))
    ;;
  remove)
    for identity in "${identities[@]}"; do
      user=${identity%%:*}
      kubectl config delete-context "$user" >/dev/null 2>&1 || true
      kubectl config delete-user "$user" >/dev/null 2>&1 || true
    done
    ;;
  *)
    echo "usage: $0 [issue|check|remove]" >&2
    exit 2
    ;;
esac
