#!/usr/bin/env bash
# Teste ponta a ponta pelo load balancer do Ingress (o "curl para a URL do Load Balancer" do vídeo):
#   chave de API -> flag -> regra de 50% -> avaliações -> eventos no SQS -> itens no DynamoDB.
source "$(dirname "$0")/lib.sh"
need curl jq aws
check_credentials
LB=$(state_get INGRESS_LB)
[ -n "$LB" ] || LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
[ -n "$LB" ] || die "Ingress sem load balancer; rode o 04-cluster-addons.sh"
BASE="http://$LB"
FLAG="${FLAG_NAME:-enable-new-dashboard}"

log "Aguardando o DNS do load balancer responder ($BASE/health)"
for _ in $(seq 1 30); do
  curl -s -m 5 -o /dev/null -w '' "$BASE/health" && break
  sleep 10
done
curl -s -m 5 "$BASE/health" || die "load balancer ainda não responde; tente de novo em alguns minutos"
echo

log "1. Chave de API no auth-service (MASTER_KEY)"
KEY=$(curl -s -X POST "$BASE/admin/keys" -H "Content-Type: application/json" \
        -H "Authorization: Bearer $MASTER_KEY" -d '{"name":"smoke-test"}' | jq -r .key)
[ "$KEY" != "null" ] && [ -n "$KEY" ] || die "não consegui criar a chave; veja: kubectl -n $K8S_NAMESPACE logs deploy/auth-service"
info "chave: ${KEY:0:12}..."

log "2. Flag '$FLAG' no flag-service"
curl -s -X POST "$BASE/flags" -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
  -d "{\"name\":\"$FLAG\",\"description\":\"smoke test\",\"is_enabled\":true}" | jq -c .

log "3. Regra de 50% no targeting-service"
curl -s -X POST "$BASE/rules" -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
  -d "{\"flag_name\":\"$FLAG\",\"is_enabled\":true,\"rules\":{\"type\":\"PERCENTAGE\",\"value\":50}}" | jq -c .

log "4. Avaliações no evaluation-service (a segunda chamada do mesmo usuário vem do cache Redis)"
for u in user-123 user-123 user-abc user-xyz; do
  curl -s "$BASE/evaluate?user_id=$u&flag_name=$FLAG"; echo
done

log "5. Pipeline SQS -> analytics-service -> DynamoDB"
sleep 10
kubectl -n "$K8S_NAMESPACE" logs deploy/analytics-service --tail=6
echo
info "itens na tabela $DYNAMODB_TABLE: $(aws dynamodb scan --table-name "$DYNAMODB_TABLE" --select COUNT --query Count --output text)"
aws dynamodb scan --table-name "$DYNAMODB_TABLE" --max-items 3 --query 'Items[].{user:user_id.S,flag:flag_name.S,result:result.BOOL}' --output table
