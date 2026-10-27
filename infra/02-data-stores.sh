#!/usr/bin/env bash
# Item 2 do PDF - bancos e fila:
#   3x RDS for PostgreSQL (auth, flag, targeting)   -> recursos 1, 2 e 3
#   1x ElastiCache for Redis (evaluation)            -> recurso 4
#   1x tabela DynamoDB (analytics)                   -> recurso 5
#   1x fila SQS Standard (evaluation -> analytics)   -> recurso 6
# Tudo na VPC default, acessível apenas de dentro da VPC (onde ficam os nós do EKS).
# Idempotente. As "strings de conexão" ficam em infra/out/state.env.
source "$(dirname "$0")/lib.sh"
need aws
check_credentials

VPC=$(default_vpc)
CIDR=$(vpc_cidr "$VPC")
SUBNETS=$(eks_subnets "$VPC")
info "VPC $VPC ($CIDR), subnets: $SUBNETS"

# ------------------------------------------------------------ security group
log "Security group $PROJECT-data (5432 e 6379 liberados para a VPC)"
SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=$PROJECT-data" \
      --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG" = "None" ] || [ -z "$SG" ]; then
  SG=$(aws ec2 create-security-group --group-name "$PROJECT-data" --vpc-id "$VPC" \
        --description "ToggleMaster: RDS e ElastiCache" --query GroupId --output text)
fi
for port in 5432 6379; do
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port "$port" --cidr "$CIDR" >/dev/null 2>&1 || true
done
state_set DATA_SG "$SG"

# ------------------------------------------------------------ senha do banco
DB_PASSWORD=$(state_get DB_PASSWORD)
if [ -z "$DB_PASSWORD" ]; then
  DB_PASSWORD=$(random_password)
  state_set DB_PASSWORD "$DB_PASSWORD"
fi
state_set DB_USER "$DB_USER"

# ------------------------------------------------------------ RDS (3 instâncias)
log "DB subnet group $PROJECT-db"
aws rds describe-db-subnet-groups --db-subnet-group-name "$PROJECT-db" >/dev/null 2>&1 \
  || aws rds create-db-subnet-group --db-subnet-group-name "$PROJECT-db" \
       --db-subnet-group-description "ToggleMaster" --subnet-ids $SUBNETS >/dev/null

for svc in auth flag targeting; do
  id="$PROJECT-$svc-db"
  log "RDS $id (banco ${DB_NAME[$svc]}, $DB_INSTANCE_CLASS, postgres $DB_ENGINE_VERSION)"
  if aws rds describe-db-instances --db-instance-identifier "$id" >/dev/null 2>&1; then
    info "já existe"
  else
    aws rds create-db-instance \
      --db-instance-identifier "$id" \
      --db-instance-class "$DB_INSTANCE_CLASS" \
      --engine postgres --engine-version "$DB_ENGINE_VERSION" \
      --allocated-storage 20 --storage-type gp3 \
      --master-username "$DB_USER" --master-user-password "$DB_PASSWORD" \
      --db-name "${DB_NAME[$svc]}" \
      --vpc-security-group-ids "$SG" --db-subnet-group-name "$PROJECT-db" \
      --no-publicly-accessible --no-multi-az \
      --backup-retention-period 0 --no-deletion-protection \
      --tags Key=project,Value="$PROJECT" >/dev/null
    info "criação iniciada"
  fi
done

# ------------------------------------------------------------ ElastiCache (Redis)
log "ElastiCache $PROJECT-redis ($CACHE_NODE_TYPE)"
aws elasticache describe-cache-subnet-groups --cache-subnet-group-name "$PROJECT-cache" >/dev/null 2>&1 \
  || aws elasticache create-cache-subnet-group --cache-subnet-group-name "$PROJECT-cache" \
       --cache-subnet-group-description "ToggleMaster" --subnet-ids $SUBNETS >/dev/null
if aws elasticache describe-cache-clusters --cache-cluster-id "$PROJECT-redis" >/dev/null 2>&1; then
  info "já existe"
else
  aws elasticache create-cache-cluster \
    --cache-cluster-id "$PROJECT-redis" --engine redis \
    --cache-node-type "$CACHE_NODE_TYPE" --num-cache-nodes 1 \
    --cache-subnet-group-name "$PROJECT-cache" --security-group-ids "$SG" \
    --tags Key=project,Value="$PROJECT" >/dev/null
  info "criação iniciada"
fi

# ------------------------------------------------------------ DynamoDB
log "DynamoDB $DYNAMODB_TABLE (chave primária event_id)"
aws dynamodb describe-table --table-name "$DYNAMODB_TABLE" >/dev/null 2>&1 \
  || aws dynamodb create-table --table-name "$DYNAMODB_TABLE" \
       --attribute-definitions AttributeName=event_id,AttributeType=S \
       --key-schema AttributeName=event_id,KeyType=HASH \
       --billing-mode PAY_PER_REQUEST --tags Key=project,Value="$PROJECT" >/dev/null
state_set DYNAMODB_TABLE "$DYNAMODB_TABLE"

# ------------------------------------------------------------ SQS
log "SQS $SQS_QUEUE_NAME (Standard)"
SQS_URL=$(aws sqs create-queue --queue-name "$SQS_QUEUE_NAME" --query QueueUrl --output text)
SQS_ARN=$(aws sqs get-queue-attributes --queue-url "$SQS_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)
state_set SQS_URL "$SQS_URL"
state_set SQS_ARN "$SQS_ARN"

# ------------------------------------------------------------ aguarda e coleta endpoints
log "Aguardando RDS ficar disponível (5 a 10 min)"
for svc in auth flag targeting; do
  id="$PROJECT-$svc-db"
  aws rds wait db-instance-available --db-instance-identifier "$id"
  host=$(aws rds describe-db-instances --db-instance-identifier "$id" --query 'DBInstances[0].Endpoint.Address' --output text)
  key=$(echo "$svc" | tr '[:lower:]' '[:upper:]')
  state_set "${key}_DB_HOST" "$host"
  state_set "${key}_DATABASE_URL" "postgres://$DB_USER:$DB_PASSWORD@$host:5432/${DB_NAME[$svc]}?sslmode=require"
  info "$id -> $host"
done

log "Aguardando ElastiCache ficar disponível"
aws elasticache wait cache-cluster-available --cache-cluster-id "$PROJECT-redis"
REDIS_HOST=$(aws elasticache describe-cache-clusters --cache-cluster-id "$PROJECT-redis" --show-cache-node-info \
              --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' --output text)
state_set REDIS_HOST "$REDIS_HOST"
state_set REDIS_URL "redis://$REDIS_HOST:6379"
info "$PROJECT-redis -> $REDIS_HOST"

log "Strings de conexão salvas em $STATE_FILE"
grep -E '^(AUTH|FLAG|TARGETING)_DB_HOST=|^REDIS_HOST=|^SQS_URL=|^SQS_ARN=|^DYNAMODB_TABLE=' "$STATE_FILE"
