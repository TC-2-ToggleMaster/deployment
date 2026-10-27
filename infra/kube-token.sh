#!/usr/bin/env bash
# Plugin de autenticação do kubeconfig: carrega as credenciais do AWS Academy do .env da raiz
# e devolve o token do EKS. Assim o kubectl funciona em qualquer terminal, mesmo que o shell
# esteja logado em outra conta AWS (perfil SSO, por exemplo).
# Instalado no kubeconfig pelo 03-eks-cluster.sh. Os argumentos recebidos são ignorados.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -f "$ROOT_DIR/.env" ]; then
  set -a; . "$ROOT_DIR/.env"; set +a
fi
unset AWS_PROFILE
exec aws eks get-token --region "${AWS_REGION:-us-east-1}" --cluster-name "${CLUSTER_NAME:-togglemaster}" --output json
