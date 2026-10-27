#!/usr/bin/env bash
# Item 2 do PDF - Cluster Kubernetes (Opção A, AWS Academy):
#   cria o cluster EKS e um Managed Node Group usando a LabRole existente,
#   com auto scaling mínimo=1, desejado=2, máximo=4.
# O PDF pede o console porque "eksctl create cluster" tenta criar roles IAM;
# a AWS CLI faz exatamente o que o console faz, sem criar roles.
# Idempotente. Tempo total: 15 a 20 minutos.
source "$(dirname "$0")/lib.sh"
need aws kubectl
check_credentials

ROLE=$(lab_role_arn)
VPC=$(default_vpc)
SUBNETS=$(eks_subnets "$VPC")
info "LabRole: $ROLE"
info "Subnets (sem us-east-1e, que não suporta EKS): $SUBNETS"

# Tags que o Kubernetes usa para escolher subnets públicas ao criar o load balancer do Ingress.
log "Tags nas subnets para o load balancer"
aws ec2 create-tags --resources $SUBNETS \
  --tags Key=kubernetes.io/role/elb,Value=1 "Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=shared"

# ------------------------------------------------------------ control plane
log "Cluster EKS $CLUSTER_NAME"
if aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  info "já existe"
else
  aws eks create-cluster --name "$CLUSTER_NAME" --role-arn "$ROLE" \
    ${EKS_VERSION:+--kubernetes-version "$EKS_VERSION"} \
    --resources-vpc-config "subnetIds=$(echo $SUBNETS | tr ' ' ','),endpointPublicAccess=true,endpointPrivateAccess=true" \
    --access-config authenticationMode=API_AND_CONFIG_MAP,bootstrapClusterCreatorAdminPermissions=true \
    --tags project="$PROJECT" >/dev/null
  info "criação iniciada"
fi
log "Aguardando control plane ACTIVE (10 a 15 min)"
aws eks wait cluster-active --name "$CLUSTER_NAME"
info "versão: $(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.version --output text)"

# ------------------------------------------------------------ launch template (IMDS hop limit 2)
# Sem IRSA (Academy), os pods pegam credenciais da LabRole pelo metadata do nó (IMDS).
# Os nós AL2023 vêm com hop limit 1, que bloqueia o IMDS para os pods; o launch template
# sobe para 2 mantendo IMDSv2 obrigatório. Sem isso, evaluation e analytics não acessam SQS/DynamoDB.
log "Launch template $PROJECT-node (IMDSv2, hop limit 2)"
LT_ID=$(aws ec2 describe-launch-templates --filters "Name=launch-template-name,Values=$PROJECT-node" \
          --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null || true)
if [ -z "$LT_ID" ] || [ "$LT_ID" = "None" ]; then
  LT_ID=$(aws ec2 create-launch-template --launch-template-name "$PROJECT-node" \
    --launch-template-data "{\"InstanceType\":\"$NODE_INSTANCE_TYPE\",\"MetadataOptions\":{\"HttpTokens\":\"required\",\"HttpPutResponseHopLimit\":2,\"HttpEndpoint\":\"enabled\"},\"BlockDeviceMappings\":[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":20,\"VolumeType\":\"gp3\"}}],\"TagSpecifications\":[{\"ResourceType\":\"instance\",\"Tags\":[{\"Key\":\"project\",\"Value\":\"$PROJECT\"}]}]}" \
    --query 'LaunchTemplate.LaunchTemplateId' --output text)
fi
info "$LT_ID"

# ------------------------------------------------------------ node group
log "Managed Node Group $NODEGROUP_NAME ($NODE_INSTANCE_TYPE, min=$NODE_MIN desejado=$NODE_DESIRED max=$NODE_MAX)"
if aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" >/dev/null 2>&1; then
  info "já existe"
else
  aws eks create-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" \
    --node-role "$ROLE" --subnets $SUBNETS \
    --launch-template "id=$LT_ID,version=\$Latest" --ami-type AL2023_x86_64_STANDARD \
    --scaling-config "minSize=$NODE_MIN,maxSize=$NODE_MAX,desiredSize=$NODE_DESIRED" \
    --tags project="$PROJECT" >/dev/null
  info "criação iniciada"
fi
log "Aguardando nós ACTIVE (3 a 5 min)"
aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME"

# Garante o hop limit 2 também em nós de um node group criado antes do launch template.
for i in $(aws ec2 describe-instances --filters "Name=tag:eks:nodegroup-name,Values=$NODEGROUP_NAME" Name=instance-state-name,Values=running \
             --query 'Reservations[].Instances[?MetadataOptions.HttpPutResponseHopLimit==`1`].InstanceId' --output text); do
  info "ajustando IMDS hop limit em $i"
  aws ec2 modify-instance-metadata-options --instance-id "$i" --http-put-response-hop-limit 2 --http-tokens required >/dev/null
done

# ------------------------------------------------------------ kubeconfig
log "kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME" >/dev/null
# Troca o "aws eks get-token" do kubeconfig pelo wrapper que lê o .env, para o kubectl
# funcionar mesmo em terminais logados em outra conta AWS.
KUBE_USER=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CLUSTER_NAME')].context.user}")
kubectl config set-credentials "$KUBE_USER" \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command="$INFRA_DIR/kube-token.sh" >/dev/null
check_kubectl_skew
kubectl get nodes -o wide

state_set CLUSTER_NAME "$CLUSTER_NAME"
state_set CLUSTER_ENDPOINT "$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.endpoint --output text)"
