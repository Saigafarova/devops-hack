#!/bin/bash


set -e


CLUSTER_NAME="devops"
K8S_DIR="k8s"
LOGGING_DIR="logging"
MONITORING_DIR="monitoring"


echo "=== 1. Проверка инструментов ==="
for tool in kind kubectl helm docker; do
  if ! command -v $tool &> /dev/null; then
    echo "Ошибка: $tool не установлен"
    exit 1
  fi
done
echo "Все инструменты на месте"


echo "=== 2. Создание kind-кластера ==="
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "Кластер ${CLUSTER_NAME} уже существует"
else
  kind create cluster --name ${CLUSTER_NAME} --config scripts/kind-config.yaml
fi


echo "=== 3. Загрузка образов в kind ==="
IMAGES=(
  "nginx:1.27"
  "busybox:latest"
  "envoyproxy/gateway:v1.9.2"
  "envoyproxy/envoy:distroless-v1.39.1"
  "envoyproxy/ratelimit:master"
  "prom/prometheus:v2.54.1"
  "docker.elastic.co/beats/filebeat:8.15.0"
)


for img in "${IMAGES[@]}"; do
  echo "Загрузка $img..."
  docker pull --platform linux/amd64 "$img" || true
  docker save "$img" | docker exec -i ${CLUSTER_NAME}-control-plane ctr --namespace=k8s.io images import - || true
done


echo "=== 4. Установка CRD Gateway API ==="
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml


echo "=== 5. Установка Envoy Gateway ==="
if ! helm list -n envoy-gateway-system 2>/dev/null | grep -q "^eg"; then
  helm install eg ./gateway-helm \
    -n envoy-gateway-system \
    --create-namespace \
    --set deployment.envoyGateway.image.repository=envoyproxy/gateway \
    --set deployment.envoyGateway.image.tag=v1.9.2 \
    --set deployment.envoyGateway.imagePullPolicy=IfNotPresent
fi

echo "Ждём регистрацию CRD Envoy Gateway"
sleep 15


echo "=== 6. Создаём EnvoyProxy (без digest) ==="
cat <<EOF | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: custom-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort
      envoyDeployment:
        container:
          image: docker.io/envoyproxy/envoy:distroless-v1.39.1
EOF


echo "=== 7. Привязываем EnvoyProxy к GatewayClass ==="
kubectl apply -f ${K8S_DIR}/gatewayclass.yaml || true


kubectl patch gatewayclass eg --type=merge -p '
spec:
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: custom-proxy
    namespace: envoy-gateway-system
' || true


echo "=== 8. Применение манифестов приложения ==="
kubectl apply -f ${K8S_DIR}/nginx-deployment.yaml
kubectl apply -f ${K8S_DIR}/nginx-service.yaml
kubectl apply -f ${K8S_DIR}/gateway.yaml
kubectl apply -f ${K8S_DIR}/httproute.yaml


echo "=== 9. Переводим Gateway Service на NodePort ==="
for i in {1..30}; do
  if kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=my-gateway &>/dev/null; then
    break
  fi
  sleep 2
done


kubectl patch svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=my-gateway \
  -p '{"spec":{"type":"NodePort"}}' || true


echo "=== 10. Установка Prometheus ==="
kubectl apply -f ${MONITORING_DIR}/prometheus-config.yaml
kubectl apply -f ${MONITORING_DIR}/prometheus-deployment.yaml
kubectl apply -f ${MONITORING_DIR}/prometheus-service.yaml


echo "=== 11. Установка Filebeat ==="
kubectl apply -f ${LOGGING_DIR}/filebeat-rbac.yaml
kubectl apply -f ${LOGGING_DIR}/filebeat-config.yaml
kubectl apply -f ${LOGGING_DIR}/filebeat-daemonset.yaml



echo "=== Ожидание PROGRAMMED: True ==="
for i in {1..60}; do
  PROGRAMMED=$(kubectl get gateway my-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
  if [ "$PROGRAMMED" = "True" ]; then
    echo "Gateway PROGRAMMED: True"
    break
  fi
  echo "Ожидание... ($i/60)"
  sleep 5
done

echo "=== 12. Ожидание готовности подов ==="
kubectl wait --timeout=180s --for=condition=Ready pod -l app=nginx || true
kubectl wait --timeout=180s --for=condition=Ready pod -l app=prometheus || true
kubectl wait --timeout=180s --for=condition=Ready pod -l app=filebeat || true


echo ""
echo "=== Готово ==="
echo ""
kubectl get pods -A
echo ""
kubectl get gateway
echo ""
kubectl get httproute
echo ""

SVC_NAME=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=my-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -n "$SVC_NAME" ]; then
  echo "Переводим $SVC_NAME на NodePort..."
  kubectl patch svc "$SVC_NAME" -n envoy-gateway-system -p '{"spec":{"type":"NodePort"}}' || true
fi

echo ""
echo "Gateway NodePort:"
kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=my-gateway -o jsonpath='{.items[0].spec.ports[0].nodePort}' 2>/dev/null || echo "ещё не готов"
echo ""