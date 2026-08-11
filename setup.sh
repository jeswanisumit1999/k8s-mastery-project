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
echo "== 6. Install Helm if missing =="
echo "=================================================="
if ! command -v helm &> /dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version

echo "=================================================="
echo "== 7. Clean up any leftover unmanaged resources =="
echo "== (Helm refuses to adopt resources it didn't create) =="
echo "=================================================="
kubectl delete secret backend-secret -n dev --ignore-not-found
kubectl delete configmap backend-config -n dev --ignore-not-found
kubectl delete resourcequota dev-quota -n dev --ignore-not-found
kubectl delete pvc postgres-pvc -n dev --ignore-not-found
kubectl delete statefulset postgres -n dev --ignore-not-found
kubectl delete deployment backend frontend -n dev --ignore-not-found
kubectl delete svc backend-service frontend-service postgres -n dev --ignore-not-found
kubectl delete cronjob postgres-backup -n dev --ignore-not-found
kubectl delete jobs -n dev --all --ignore-not-found
echo "Waiting for old pods to fully terminate..."
kubectl wait --for=delete pod -l app=backend -n dev --timeout=60s 2>/dev/null || true
kubectl wait --for=delete pod -l app=postgres -n dev --timeout=60s 2>/dev/null || true

echo "=================================================="
echo "== 8. Deploy via Helm (idempotent: installs or upgrades) =="
echo "=================================================="
cd "$PROJECT_DIR"
helm upgrade --install taskapp ./taskapp --namespace dev --wait --timeout 3m
helm list -n dev

echo "=================================================="
echo "== 8b. Apply extras not yet in the Helm chart =="
echo "== (node-exporter DaemonSet, backup CronJob) =="
echo "=================================================="
kubectl apply -f node-exporter-daemonset.yaml
kubectl apply -f postgres-backup-cronjob.yaml

echo "=================================================="
echo "== 9. Load seed data (only if items table is empty) =="
echo "=================================================="
kubectl wait --for=condition=Ready pod/postgres-0 -n dev --timeout=120s
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
kubectl get resourcequota -n dev
