#!/usr/bin/env bash
# Provisiona e implanta tudo, na ordem dos itens 2 a 5 do PDF. Cada etapa é idempotente,
# então se a sessão do AWS Academy expirar no meio, renove o .env e rode de novo.
# Tempo total: 30 a 40 minutos.
cd "$(dirname "$0")"
set -e
./01-ecr-push.sh
./02-data-stores.sh
./03-eks-cluster.sh
./04-cluster-addons.sh
./05-init-databases.sh
./06-deploy-app.sh
./07-smoke-test.sh
