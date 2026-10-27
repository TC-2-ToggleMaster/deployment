#!/usr/bin/env bash
# Item 2 do PDF - Registro de Contêineres (ECR):
#   cria 5 repositórios (um por microsserviço) e publica as imagens da etapa 1.
# Idempotente: repositórios existentes são reutilizados; a imagem é reconstruída e enviada.
source "$(dirname "$0")/lib.sh"
need aws docker
check_credentials

ACCOUNT=$(aws_account)
ECR="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"

log "Login no ECR ($ECR)"
aws ecr get-login-password | docker login --username AWS --password-stdin "$ECR"

for svc in "${SERVICES[@]}"; do
  repo="$PROJECT-$svc"
  dir="$ROOT_DIR/${SERVICE_DIR[$svc]}"
  log "$repo  <-  $dir"
  aws ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$repo" \
         --image-scanning-configuration scanOnPush=true \
         --tags Key=project,Value="$PROJECT" >/dev/null
  info "docker build"
  docker build -q -t "$ECR/$repo:$IMAGE_TAG" "$dir" >/dev/null
  info "docker push $ECR/$repo:$IMAGE_TAG"
  docker push -q "$ECR/$repo:$IMAGE_TAG" >/dev/null
done

state_set ACCOUNT_ID "$ACCOUNT"
state_set ECR_REGISTRY "$ECR"

log "Repositórios publicados"
aws ecr describe-repositories \
  --query "repositories[?starts_with(repositoryName,'$PROJECT-')].repositoryUri" --output table
