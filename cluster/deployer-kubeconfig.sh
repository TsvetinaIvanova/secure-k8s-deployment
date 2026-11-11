#!/usr/bin/env bash
# Write a kubeconfig for the deployer ServiceAccount (platform/rbac/deployer.yaml) with a
# fresh token from the TokenRequest API, valid for 10 minutes (the API's minimum).
# Run by `make deploy` before each Helm run, using the admin kubeconfig in $KUBECONFIG.
#
# The token is written into the file by the shell, never passed as a command-line argument,
# so it doesn't show up in `ps`. The file is created mode 600 and lives in .kube/ (gitignored).
#
# Usage: deployer-kubeconfig.sh <kubectl binary> <output file>
set -euo pipefail

KUBECTL=${1:?kubectl binary}
OUT=${2:?output file}

server=$("$KUBECTL" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
ca=$("$KUBECTL" config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
token=$("$KUBECTL" -n deploy create token app-deployer --duration=10m)

umask 077
cat >"$OUT.tmp" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: secure-k8s
    cluster:
      server: $server
      certificate-authority-data: $ca
users:
  - name: app-deployer
    user:
      token: $token
contexts:
  - name: app-deployer
    context: {cluster: secure-k8s, user: app-deployer, namespace: app}
current-context: app-deployer
EOF
mv "$OUT.tmp" "$OUT"
echo "wrote $OUT (deploy/app-deployer, token valid 10m)"
