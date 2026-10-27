#!/usr/bin/env bash
# Itens 4 e 5 do PDF - aplica os manifestos do diretório deployment/:
#   Namespace, Secrets (gerados a partir do state.env, em base64), ConfigMap,
#   Deployments + Services ClusterIP, Ingress e HPAs.
# Os arquivos versionados não são alterados: as versões preenchidas ficam em infra/out/k8s/
# e os Secrets também em deployment/secrets.yaml (ignorado pelo git).
source "$(dirname "$0")/lib.sh"
need kubectl
for v in ECR_REGISTRY AUTH_DATABASE_URL FLAG_DATABASE_URL TARGETING_DATABASE_URL REDIS_URL SQS_URL CLUSTER_NAME; do
  [ -n "${!v:-}" ] || die "$v não está em $STATE_FILE; rode os scripts 01, 02 e 03 antes"
done

R="$OUT_DIR/k8s"; mkdir -p "$R"

log "Renderizando manifestos em $R"
cp "$DEPLOY_DIR/namespace.yaml" "$DEPLOY_DIR/ingress.yaml" "$DEPLOY_DIR/hpa.yaml" "$R/"
# Imagens: troca apenas o host do registry, preservando os nomes das variáveis AWS_REGION nos env.
sed -e "s#ACCOUNT_ID.dkr.ecr.AWS_REGION.amazonaws.com#$ECR_REGISTRY#g" \
    -e "s#:latest#:$IMAGE_TAG#g" "$DEPLOY_DIR/apps.yaml" > "$R/apps.yaml"
sed -e "s#REPLACE_WITH_AWS_REGION#$AWS_REGION#g" \
    -e "s#REPLACE_WITH_SQS_QUEUE_URL#$SQS_URL#g" \
    -e "s#ToggleMasterAnalytics#$DYNAMODB_TABLE#g" "$DEPLOY_DIR/configmap.yaml" > "$R/configmap.yaml"

cat > "$R/secrets.yaml" <<EOF
# Gerado por infra/06-deploy-app.sh em $(date -u +%Y-%m-%dT%H:%M:%SZ). NÃO versionar.
apiVersion: v1
kind: Secret
metadata:
  name: auth-secret
  namespace: $K8S_NAMESPACE
type: Opaque
data:
  DATABASE_URL: $(b64 "$AUTH_DATABASE_URL")
  MASTER_KEY: $(b64 "$MASTER_KEY")
---
apiVersion: v1
kind: Secret
metadata:
  name: flag-secret
  namespace: $K8S_NAMESPACE
type: Opaque
data:
  DATABASE_URL: $(b64 "$FLAG_DATABASE_URL")
---
apiVersion: v1
kind: Secret
metadata:
  name: targeting-secret
  namespace: $K8S_NAMESPACE
type: Opaque
data:
  DATABASE_URL: $(b64 "$TARGETING_DATABASE_URL")
---
apiVersion: v1
kind: Secret
metadata:
  name: evaluation-secret
  namespace: $K8S_NAMESPACE
type: Opaque
data:
  REDIS_URL: $(b64 "$REDIS_URL")
  SERVICE_API_KEY: $(b64 "$SERVICE_API_KEY")
EOF
cp "$R/secrets.yaml" "$DEPLOY_DIR/secrets.yaml"

log "Aplicando no cluster $CLUSTER_NAME"
kubectl apply -f "$R/namespace.yaml"
kubectl apply -f "$R/secrets.yaml"
kubectl apply -f "$R/configmap.yaml"
kubectl apply -f "$R/apps.yaml"
kubectl apply -f "$R/ingress.yaml"
kubectl apply -f "$R/hpa.yaml"

log "Aguardando rollout dos 5 Deployments"
for svc in "${SERVICES[@]}"; do
  kubectl -n "$K8S_NAMESPACE" rollout status "deploy/${SERVICE_DIR[$svc]}" --timeout=300s
done

log "Estado"
kubectl -n "$K8S_NAMESPACE" get pods -o wide
kubectl -n "$K8S_NAMESPACE" get svc,ingress,hpa

LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
[ -n "$LB" ] && state_set INGRESS_LB "$LB"
log "URL pública (Ingress): http://${LB:-<pendente>}"
info "Teste: ./07-smoke-test.sh"
