# ToggleMaster Kubernetes manifests

These manifests implement the Kubernetes deliverables in the Tech Challenge:
one application namespace, five Deployments and ClusterIP Services, shared
service configuration, per-service Secret resources, an Ingress, and CPU-based
HPAs for evaluation and analytics.

## Before applying

Build and push the five images to ECR first, then replace `ACCOUNT_ID` and
`AWS_REGION` in `apps.yaml` with the image registry values. The service
directories contain multi-stage Dockerfiles that build as non-root runtime
images. Their `.dockerignore` files exclude `.env` files from build contexts.

From the repository root in Git Bash, set your account and region, authenticate
Docker to ECR, then build and push the images:

```bash
AWS_ACCOUNT_ID="123456789012"
AWS_REGION="us-east-1"
ECR="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR"

docker build -t "$ECR/togglemaster-auth:latest" ./auth-service
docker push "$ECR/togglemaster-auth:latest"
docker build -t "$ECR/togglemaster-flag:latest" ./flag-service
docker push "$ECR/togglemaster-flag:latest"
docker build -t "$ECR/togglemaster-targeting:latest" ./targeting-service
docker push "$ECR/togglemaster-targeting:latest"
docker build -t "$ECR/togglemaster-evaluation:latest" ./evaluation-service
docker push "$ECR/togglemaster-evaluation:latest"
docker build -t "$ECR/togglemaster-analytics:latest" ./analytics-service
docker push "$ECR/togglemaster-analytics:latest"
```

Replace the sample account ID and region with the values for your ECR
repositories. For repeatable releases, use immutable version tags instead of
`latest` and update the image references in `apps.yaml` to match.

Update `configmap.yaml` with the actual AWS region and SQS queue URL. The
DynamoDB table name defaults to `ToggleMasterAnalytics`, matching
`analytics-service`.

`secrets.template.yaml` contains only base64-encoded placeholder strings. Copy
it to `secrets.yaml` and replace each placeholder with the base64 encoding of
the real value before applying. Do not commit `secrets.yaml`; it is ignored by
this directory's `.gitignore`. Base64 is encoding, not encryption. Enable
encryption at rest for Kubernetes Secrets and restrict RBAC access in a real
environment.

For example, in Git Bash, encode a value without a trailing newline:

```bash
printf %s "$DATABASE_URL" | base64
```

Set these secret values:

- `auth-secret`: `DATABASE_URL`, `MASTER_KEY`
- `flag-secret`: `DATABASE_URL`
- `targeting-secret`: `DATABASE_URL`
- `evaluation-secret`: `REDIS_URL`, `SERVICE_API_KEY`

The AWS SDKs in evaluation and analytics use the default AWS credential
provider chain. Do not put temporary AWS Academy credentials in these
manifests. Configure the EKS node role used by the lab with the required SQS
and DynamoDB permissions, and verify that the pods can obtain those role
credentials. For a personal AWS account, prefer a workload identity mechanism
such as EKS Pod Identity or IRSA.

Install the NGINX Ingress Controller and Kubernetes Metrics Server in the
cluster before applying these manifests. The controller's LoadBalancer and
other AWS network resources may incur charges.

## Apply and verify

From the repository root, after replacing image references and configuration
and creating `deployment/secrets.yaml`:

```bash
kubectl apply -f deployment/namespace.yaml
kubectl apply -f deployment/configmap.yaml
kubectl apply -f deployment/secrets.yaml
kubectl apply -f deployment/apps.yaml
kubectl apply -f deployment/ingress.yaml
kubectl apply -f deployment/hpa.yaml
```

Check rollout, ingress, and autoscalers:

```bash
kubectl get pods,services,ingress,hpa -n togglemaster
kubectl get nodes
```

The Ingress preserves the applications' existing endpoint paths: `/validate`
and `/admin` go to auth; `/flags` to flag; `/rules` to targeting; and
`/evaluate` and `/health` to evaluation. Get the external address with:

```bash
kubectl get ingress togglemaster-ingress -n togglemaster
```

Use that address in place of `localhost` in the existing curl examples. The
AWS Academy lab may restrict the NGINX controller's ability to provision a
LoadBalancer; if the Ingress has no address, check controller events and the
cluster's permissions.
