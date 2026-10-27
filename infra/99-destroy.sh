#!/usr/bin/env bash
# Remove TUDO que os scripts criaram, na ordem inversa, para não gastar créditos do Academy.
#   ./99-destroy.sh          pede confirmação
#   ./99-destroy.sh --yes    sem confirmação
#   KEEP_DATA=1 ./99-destroy.sh   mantém DynamoDB, SQS e ECR
source "$(dirname "$0")/lib.sh"
need aws
check_credentials

if [ "${1:-}" != "--yes" ]; then
  echo "Isso apaga: cluster EKS $CLUSTER_NAME, node group, load balancer, 3 RDS, ElastiCache,"
  echo "security group, subnet groups${KEEP_DATA:+ (mantendo DynamoDB, SQS e ECR)}${KEEP_DATA:-, DynamoDB, SQS e os 5 repositórios ECR}."
  read -r -p "Digite 'sim' para confirmar: " ok
  [ "$ok" = "sim" ] || { echo "cancelado"; exit 0; }
fi

# ------------------------------------------------------------ Kubernetes (libera o NLB antes do cluster)
if aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME" >/dev/null 2>&1 || true
  log "Removendo aplicações e o Ingress Controller (apaga o load balancer)"
  kubectl delete ns "$K8S_NAMESPACE" --ignore-not-found --timeout=120s 2>/dev/null || true
  kubectl delete ns ingress-nginx --ignore-not-found --timeout=180s 2>/dev/null || true
  sleep 30

  log "Removendo node group $NODEGROUP_NAME"
  if aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" >/dev/null 2>&1; then
    aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" >/dev/null
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME"
  fi
  log "Removendo cluster $CLUSTER_NAME (5 a 10 min)"
  aws eks delete-cluster --name "$CLUSTER_NAME" >/dev/null
  aws eks wait cluster-deleted --name "$CLUSTER_NAME"
  kubectl config delete-context "$CLUSTER_NAME" >/dev/null 2>&1 || true
fi
aws ec2 delete-launch-template --launch-template-name "$PROJECT-node" >/dev/null 2>&1 || true

# ------------------------------------------------------------ RDS e ElastiCache
for svc in auth flag targeting; do
  id="$PROJECT-$svc-db"
  if aws rds describe-db-instances --db-instance-identifier "$id" >/dev/null 2>&1; then
    log "Removendo RDS $id"
    aws rds delete-db-instance --db-instance-identifier "$id" --skip-final-snapshot --delete-automated-backups >/dev/null
  fi
done
if aws elasticache describe-cache-clusters --cache-cluster-id "$PROJECT-redis" >/dev/null 2>&1; then
  log "Removendo ElastiCache $PROJECT-redis"
  aws elasticache delete-cache-cluster --cache-cluster-id "$PROJECT-redis" >/dev/null
fi
log "Aguardando exclusão dos bancos"
for svc in auth flag targeting; do
  aws rds wait db-instance-deleted --db-instance-identifier "$PROJECT-$svc-db" 2>/dev/null || true
done
aws elasticache wait cache-cluster-deleted --cache-cluster-id "$PROJECT-redis" 2>/dev/null || true
aws rds delete-db-subnet-group --db-subnet-group-name "$PROJECT-db" >/dev/null 2>&1 || true
aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$PROJECT-cache" >/dev/null 2>&1 || true

# ------------------------------------------------------------ security group (pode demorar a liberar as ENIs)
SG=$(state_get DATA_SG)
if [ -n "$SG" ]; then
  log "Removendo security group $SG"
  for _ in $(seq 1 12); do
    aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 && break
    sleep 10
  done
fi

# ------------------------------------------------------------ dados e registry
if [ -z "${KEEP_DATA:-}" ]; then
  log "Removendo DynamoDB, SQS e ECR"
  aws dynamodb delete-table --table-name "$DYNAMODB_TABLE" >/dev/null 2>&1 || true
  url=$(aws sqs get-queue-url --queue-name "$SQS_QUEUE_NAME" --query QueueUrl --output text 2>/dev/null || true)
  [ -n "$url" ] && aws sqs delete-queue --queue-url "$url" >/dev/null 2>&1 || true
  for svc in "${SERVICES[@]}"; do
    aws ecr delete-repository --repository-name "$PROJECT-$svc" --force >/dev/null 2>&1 || true
  done
  rm -f "$STATE_FILE"
else
  for k in CLUSTER_NAME CLUSTER_ENDPOINT INGRESS_LB DATA_SG DB_PASSWORD AUTH_DB_HOST FLAG_DB_HOST TARGETING_DB_HOST \
           AUTH_DATABASE_URL FLAG_DATABASE_URL TARGETING_DATABASE_URL REDIS_HOST REDIS_URL; do
    touch "$STATE_FILE"; grep -v "^$k=" "$STATE_FILE" > "$STATE_FILE.tmp" || true; mv "$STATE_FILE.tmp" "$STATE_FILE"
  done
fi
rm -f "$DEPLOY_DIR/secrets.yaml"

log "Concluído. Confira no console se sobrou algum load balancer ou volume EBS órfão."
