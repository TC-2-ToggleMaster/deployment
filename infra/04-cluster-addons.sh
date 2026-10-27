#!/usr/bin/env bash
# Item 3 do PDF - Configurando o cluster:
#   Metrics Server (necessário para o HPA) e Nginx Ingress Controller.
# Instala via "kubectl apply" (não precisa de Helm). Como os nós usam a LabRole,
# o Service do tipo LoadBalancer do Nginx cria um Network Load Balancer na AWS.
# Idempotente.
source "$(dirname "$0")/lib.sh"
need aws kubectl curl
check_credentials
[ -n "$(state_get CLUSTER_NAME)" ] || die "rode antes o 03-eks-cluster.sh"
check_kubectl_skew

# ------------------------------------------------------------ Metrics Server
log "Metrics Server"
kubectl apply -f "$METRICS_SERVER_URL"
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s

# ------------------------------------------------------------ Nginx Ingress Controller
log "Nginx Ingress Controller ($INGRESS_NGINX_VERSION, provider aws/NLB)"
MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_NGINX_VERSION/deploy/static/provider/aws/deploy.yaml"
curl -fsSL -o "$OUT_DIR/ingress-nginx.yaml" "$MANIFEST" \
  || die "não achei o manifesto para $INGRESS_NGINX_VERSION. Ajuste INGRESS_NGINX_VERSION para uma tag de https://github.com/kubernetes/ingress-nginx/releases"
kubectl apply -f "$OUT_DIR/ingress-nginx.yaml"
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s

log "Aguardando a AWS criar o load balancer (2 a 4 min)"
LB=""
for _ in $(seq 1 36); do
  LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$LB" ] && break
  sleep 10
done
[ -n "$LB" ] || die "load balancer não apareceu. Verifique: kubectl -n ingress-nginx describe svc ingress-nginx-controller"
state_set INGRESS_LB "$LB"
info "Load balancer: $LB"
info "O DNS do NLB leva mais alguns minutos para responder; teste com: curl http://$LB/health"

log "Metrics Server funcionando?"
kubectl top nodes 2>/dev/null || info "métricas ainda não disponíveis; tente 'kubectl top nodes' em 1 minuto"
