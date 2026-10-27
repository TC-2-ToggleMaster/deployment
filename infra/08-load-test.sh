#!/usr/bin/env bash
# Demonstração do HPA do evaluation-service: sobe pods geradores de carga dentro do cluster.
#   ./08-load-test.sh          inicia 5 geradores
#   ./08-load-test.sh 10       inicia 10 geradores
#   ./08-load-test.sh stop     remove os geradores
# Acompanhe em outro terminal:  watch -n 2 kubectl -n togglemaster get hpa,pods
# ("kubectl get -w" só aceita um tipo de recurso por vez; por isso o watch.)
source "$(dirname "$0")/lib.sh"
need kubectl
FLAG="${FLAG_NAME:-enable-new-dashboard}"

if [ "${1:-}" = "stop" ]; then
  log "Removendo geradores de carga"
  kubectl -n "$K8S_NAMESPACE" delete pod -l app=load-gen --ignore-not-found
  exit 0
fi

N="${1:-5}"
log "Iniciando $N geradores de carga contra evaluation-service"
for i in $(seq 1 "$N"); do
  kubectl -n "$K8S_NAMESPACE" run "load-gen-$i" --image=busybox:1.36 --restart=Never --labels=app=load-gen -- /bin/sh -c \
    "i=0; while true; do i=\$((i+1)); wget -q -O- \"http://evaluation-service:8004/evaluate?user_id=u\$i&flag_name=$FLAG\" >/dev/null 2>&1; done" >/dev/null
done

info "A cada 15s o HPA recalcula; em 1 a 3 minutos as réplicas devem subir."
info "Acompanhe:  watch -n 2 kubectl -n $K8S_NAMESPACE get hpa,pods"
info "Pare com:   $0 stop"
echo
kubectl -n "$K8S_NAMESPACE" get hpa
