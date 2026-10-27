#!/usr/bin/env bash
# Aplica os schemas (db/init.sql de cada serviço) nos 3 RDS e cadastra a
# SERVICE_API_KEY do evaluation-service no auth-service, igual ao docker-compose.
# Os RDS não são públicos, então o psql roda em um pod temporário dentro do cluster.
# Idempotente (os scripts usam CREATE TABLE IF NOT EXISTS / ON CONFLICT DO NOTHING).
source "$(dirname "$0")/lib.sh"
need kubectl
[ -n "$(state_get AUTH_DB_HOST)" ] || die "rode antes o 02-data-stores.sh"
[ -n "$(state_get CLUSTER_NAME)" ] || die "rode antes o 03-eks-cluster.sh"

kubectl get ns "$K8S_NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$K8S_NAMESPACE" >/dev/null

# run_psql <host> <banco> [args do psql...]   (SQL pode vir pela entrada padrão)
run_psql() {
  local host=$1 db=$2; shift 2
  kubectl -n "$K8S_NAMESPACE" run "psql-init-$RANDOM" --rm -i --restart=Never --quiet \
    --image=postgres:16-alpine \
    --env="PGPASSWORD=$DB_PASSWORD" --env="PGSSLMODE=require" --env="PGCONNECT_TIMEOUT=15" \
    -- psql -v ON_ERROR_STOP=1 -h "$host" -U "$DB_USER" -d "$db" "$@"
}

log "auth-service -> $AUTH_DB_HOST/auth_db"
run_psql "$AUTH_DB_HOST" auth_db -f - < "$ROOT_DIR/auth-service/db/init.sql"
info "cadastrando SERVICE_API_KEY (apenas o SHA-256 é armazenado)"
run_psql "$AUTH_DB_HOST" auth_db -v key="$SERVICE_API_KEY" -f - <<'SQL'
INSERT INTO api_keys (name, key_hash)
VALUES ('evaluation-service', encode(sha256(convert_to(:'key', 'UTF8')), 'hex'))
ON CONFLICT (key_hash) DO NOTHING;
SQL

log "flag-service -> $FLAG_DB_HOST/flags_db"
run_psql "$FLAG_DB_HOST" flags_db -f - < "$ROOT_DIR/flag-service/db/init.sql"

log "targeting-service -> $TARGETING_DB_HOST/targeting_db"
run_psql "$TARGETING_DB_HOST" targeting_db -f - < "$ROOT_DIR/targeting-service/db/init.sql"

log "Tabelas criadas"
for svc in auth flag targeting; do
  key=$(echo "$svc" | tr '[:lower:]' '[:upper:]'); host_var="${key}_DB_HOST"
  info "$svc: $(run_psql "${!host_var}" "${DB_NAME[$svc]}" -Atc "select string_agg(tablename, ', ') from pg_tables where schemaname='public'")"
done
