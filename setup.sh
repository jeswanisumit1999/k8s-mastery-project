#!/bin/bash
set -e

REPO_URL="https://github.com/jeswanisumit1999/k8s-mastery-project.git"
PROJECT_DIR="$HOME/k8s-mastery-project"

echo "=================================================="
echo "== 1. Clone project (public repo, no token needed) =="
echo "=================================================="
rm -rf "$PROJECT_DIR"
git clone "$REPO_URL" "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo "=================================================="
echo "== 2. Build backend image =="
echo "=================================================="
cd "$PROJECT_DIR/backend"
docker build -t k8s-demo-backend:v1 .
docker save -o k8s-demo-backend.tar k8s-demo-backend:v1

echo "=================================================="
echo "== 3. Build frontend image =="
echo "=================================================="
cd "$PROJECT_DIR/frontend"
docker build -t k8s-demo-frontend:v1 .
docker save -o k8s-demo-frontend.tar k8s-demo-frontend:v1

echo "=================================================="
echo "== 4. Copy images to node01 and import into containerd =="
echo "=================================================="
scp -o StrictHostKeyChecking=no "$PROJECT_DIR/backend/k8s-demo-backend.tar" node01:/root/
scp -o StrictHostKeyChecking=no "$PROJECT_DIR/frontend/k8s-demo-frontend.tar" node01:/root/

ssh -o StrictHostKeyChecking=no node01 "ctr -n k8s.io images import /root/k8s-demo-backend.tar"
ssh -o StrictHostKeyChecking=no node01 "ctr -n k8s.io images import /root/k8s-demo-frontend.tar"

echo "=================================================="
echo "== 5. Create namespace =="
echo "=================================================="
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -

echo "=================================================="
echo "== 6. Apply manifests in dependency order =="
echo "=================================================="
cd "$PROJECT_DIR"

# Quota first, so nothing sneaks in unbounded
kubectl apply -f dev-quota.yaml

# Config/secrets before anything that consumes them
kubectl apply -f backend-configmap.yaml
kubectl apply -f backend-secrets.yaml

# Storage before the StatefulSet that claims it
kubectl apply -f postgres-pvc.yaml

# DB identity + workload before backend (init container depends on DB being reachable)
kubectl apply -f postgres-headless-svc.yaml
kubectl apply -f postgres-statefulset.yaml

echo "Waiting for postgres-0 to be ready before deploying backend..."
kubectl rollout status statefulset/postgres -n dev --timeout=120s

# Backend
kubectl apply -f backend-deployment.yaml
kubectl rollout status deployment/backend -n dev --timeout=120s

# Supporting ops workloads
kubectl apply -f node-exporter-daemonset.yaml
kubectl apply -f postgres-backup-cronjob.yaml

echo "=================================================="
echo "== 7. Load seed data (only if items table is empty) =="
echo "=================================================="
kubectl exec -it postgres-0 -n dev -- psql -U postgres -d itemsdb -c "
CREATE TABLE IF NOT EXISTS items (
  id SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  description TEXT
);
INSERT INTO items (name, description)
SELECT * FROM (VALUES
  ('Widget A', 'A basic widget'),
  ('Widget B', 'A slightly better widget'),
  ('Gadget X', 'An advanced gadget')
) AS v(name, description)
WHERE NOT EXISTS (SELECT 1 FROM items);
"

echo "=================================================="
echo "== Done. Current state: =="
echo "=================================================="
kubectl get all -n dev
kubectl get pvc -n dev
