#!/usr/bin/env bash
# Configuração e funções compartilhadas pelos scripts de infraestrutura.
# Carregue no início de cada script com:  source "$(dirname "$0")/lib.sh"
#
# Pensado para o AWS Academy (Opção A do Tech Challenge): usa apenas a LabRole,
# não cria roles IAM e usa a VPC default da conta.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$INFRA_DIR/.." && pwd)"
ROOT_DIR="$(cd "$DEPLOY_DIR/.." && pwd)"
OUT_DIR="$INFRA_DIR/out"          # artefatos gerados (ignorado pelo git)
STATE_FILE="$OUT_DIR/state.env"   # endpoints, senhas e IDs gerados pelos scripts
mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------- credenciais
# As credenciais temporárias do AWS Academy ficam no .env da raiz do projeto
# (o mesmo usado pelo docker-compose). Elas expiram a cada sessão do lab.
if [ -f "$ROOT_DIR/.env" ]; then
  set -a; . "$ROOT_DIR/.env"; set +a
fi
: "${AWS_REGION:=us-east-1}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

# ---------------------------------------------------------------- parâmetros
# Todos podem ser sobrescritos via variável de ambiente antes de rodar o script.
: "${PROJECT:=togglemaster}"
: "${CLUSTER_NAME:=$PROJECT}"
: "${NODEGROUP_NAME:=$PROJECT-ng}"
: "${NODE_INSTANCE_TYPE:=t3.medium}"
: "${NODE_MIN:=1}"
: "${NODE_DESIRED:=2}"
: "${NODE_MAX:=4}"
: "${EKS_VERSION:=}"                    # vazio = versão padrão atual da AWS
: "${DB_INSTANCE_CLASS:=db.t3.micro}"
: "${DB_ENGINE_VERSION:=16}"
: "${DB_USER:=postgres}"
: "${CACHE_NODE_TYPE:=cache.t3.micro}"
: "${DYNAMODB_TABLE:=ToggleMasterAnalytics}"
: "${SQS_QUEUE_NAME:=togglemaster-evaluation-events}"
: "${K8S_NAMESPACE:=togglemaster}"
: "${IMAGE_TAG:=latest}"
: "${METRICS_SERVER_URL:=https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml}"
: "${INGRESS_NGINX_VERSION:=controller-v1.13.0}"
: "${SERVICE_API_KEY:=tm_key_local_evaluation_service}"
: "${MASTER_KEY:=admin-secreto-123}"

# Nome curto -> diretório do serviço. O repositório ECR é "$PROJECT-<nome curto>",
# igual às imagens referenciadas em deployment/apps.yaml.
SERVICES=(auth flag targeting evaluation analytics)
declare -A SERVICE_DIR=(
  [auth]=auth-service [flag]=flag-service [targeting]=targeting-service
  [evaluation]=evaluation-service [analytics]=analytics-service
)
# Bancos relacionais: um RDS por serviço, com o nome de banco que o código espera.
declare -A DB_NAME=([auth]=auth_db [flag]=flags_db [targeting]=targeting_db)

# ---------------------------------------------------------------- utilitários
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mAVISO: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }
need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "comando '$c' não encontrado no PATH"; done; }

# Estado persistido entre scripts (chave=valor).
state_set()  { touch "$STATE_FILE"; { grep -v "^$1=" "$STATE_FILE" || true; echo "$1=$2"; } > "$STATE_FILE.tmp"; mv "$STATE_FILE.tmp" "$STATE_FILE"; }
state_get()  { [ -f "$STATE_FILE" ] && { grep "^$1=" "$STATE_FILE" | tail -1 | cut -d= -f2-; } || true; }
state_load() { if [ -f "$STATE_FILE" ]; then set -a; . "$STATE_FILE"; set +a; fi; }

check_credentials() {
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "credenciais AWS inválidas ou expiradas. No AWS Academy: AWS Details > AWS CLI > Show, e atualize $ROOT_DIR/.env"
}
aws_account()  { aws sts get-caller-identity --query Account --output text; }
lab_role_arn() { aws iam get-role --role-name LabRole --query Role.Arn --output text; }

# VPC default e suas subnets. A zona us-east-1e não suporta EKS, por isso é excluída.
default_vpc() { aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text; }
vpc_cidr()    { aws ec2 describe-vpcs --vpc-ids "$1" --query 'Vpcs[0].CidrBlock' --output text; }
eks_subnets() {
  aws ec2 describe-subnets --filters "Name=vpc-id,Values=$1" Name=default-for-az,Values=true \
    --query 'Subnets[?AvailabilityZone!=`us-east-1e`].SubnetId' --output text | tr '\t' ' '
}

# Avisa se o kubectl local estiver muito atrás da versão do cluster (skew > 1 minor).
check_kubectl_skew() {
  local client server
  client=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.minor' | tr -dc '0-9') || return 0
  server=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.version --output text 2>/dev/null | cut -d. -f2) || return 0
  if [ -n "$client" ] && [ -n "$server" ] && [ $((server - client)) -gt 1 ]; then
    warn "kubectl 1.$client é antigo para o cluster 1.$server. Atualize: veja deployment/infra/README.md (seção Pré-requisitos)."
  fi
}

# Sem "head" no fim do pipeline: com pipefail, o SIGPIPE no "tr" derrubaria o script.
random_password() { head -c 64 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c1-24; }
b64() { printf '%s' "$1" | base64 -w0; }

state_load
