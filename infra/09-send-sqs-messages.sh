#!/usr/bin/env bash
# Demonstração do HPA do analytics-service: envia mensagens manualmente para a fila SQS
# no mesmo formato que o evaluation-service produz.
#   ./09-send-sqs-messages.sh        envia 200 mensagens
#   ./09-send-sqs-messages.sh 1000   envia 1000
# Acompanhe:  watch -n 2 kubectl -n togglemaster get hpa,pods   e   kubectl -n togglemaster logs -f deploy/analytics-service
source "$(dirname "$0")/lib.sh"
need aws jq
check_credentials
[ -n "$(state_get SQS_URL)" ] || SQS_URL=$(aws sqs get-queue-url --queue-name "$SQS_QUEUE_NAME" --query QueueUrl --output text)
N="${1:-200}"
FLAG="${FLAG_NAME:-enable-new-dashboard}"

log "Enviando $N mensagens para $SQS_URL (lotes de 10)"
sent=0
while [ "$sent" -lt "$N" ]; do
  entries=$(for j in $(seq 0 9); do
    [ $((sent + j)) -lt "$N" ] || break
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -cn --arg id "m$j" --arg u "manual-$((sent + j))" --arg f "$FLAG" --arg ts "$ts" \
      '{Id:$id, MessageBody:({user_id:$u, flag_name:$f, result:true, timestamp:$ts}|tostring)}'
  done | jq -cs .)
  aws sqs send-message-batch --queue-url "$SQS_URL" --entries "$entries" >/dev/null
  sent=$((sent + 10))
  printf '\r    enviadas: %d' "$((sent > N ? N : sent))"
done
echo

info "mensagens visíveis na fila agora: $(aws sqs get-queue-attributes --queue-url "$SQS_URL" \
  --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text)"
info "Acompanhe o consumo:  kubectl -n $K8S_NAMESPACE logs -f deploy/analytics-service"
info "E o HPA:              watch -n 2 kubectl -n $K8S_NAMESPACE get hpa,pods"
