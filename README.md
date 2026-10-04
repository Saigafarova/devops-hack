# devops-hack

Развёртывание простого веб-приложения в Kubernetes с автоматизацией, Gateway API, мониторингом и логированием.

Хакатон MTS ENGINEER HACK, трек DevOps.

Что | Где
---|---
Репозиторий | https://github.com/Saigafarova/devops-hack
Скрипт развёртывания | `scripts/deploy.sh`
Конфиг kind | `scripts/kind-config.yaml`
Kubernetes-манифесты | `k8s/`
Мониторинг | `monitoring/`
Логирование | `logging/`

## Что разворачивается

| Компонент | Роль |
|---|---|
| kind | локальный Kubernetes-кластер (v1.37.0) |
| Nginx | демонстрационное веб-приложение |
| Envoy Gateway | реализация Gateway API (v1.9.2) |
| Gateway API (v1.6.1) | маршрутизация HTTP-трафика |
| Prometheus | сбор метрик Envoy Gateway (v2.54.1) |
| Filebeat | сбор access-логов Nginx (v8.15.0) |

## Основной сценарий

1. Клонировать репозиторий.
2. Запустить `./scripts/deploy.sh`.
3. Скрипт создаёт kind-кластер `devops`.
4. Загружает образы в kind (nginx, envoy, prometheus, filebeat).
5. Установить CRD Gateway API.
6. Установить Envoy Gateway через Helm.
7. Создать EnvoyProxy с типом сервиса NodePort.
8. Применить манифесты: Nginx, Service, Gateway, HTTPRoute.
9. Установить Prometheus и Filebeat.
10. Ждём готовности подов.
11. Вывести статус: pods, gateway, httproute, NodePort.

## Архитектура

```
[Пользователь]
      |
      v
[NodePort]
      |
      v
[Envoy Gateway] --- HTTPRoute ---> [nginx-service] ---> [Nginx Pods x2]
      |                                   |
      |                                   +-- access-логи в stdout
      |                                              |
      +-- метрики (порт 19001)                       v
              |                              [Filebeat DaemonSet]
              v                                      |
        [Prometheus] <--- scrape --------------------+
```

**Структура репозитория:**

```
devops-hack/
├── scripts/
│   ├── kind-config.yaml      # Конфиг kind-кластера
│   └── deploy.sh             # Скрипт автоматизации
├── k8s/
│   ├── nginx-deployment.yaml
│   ├── nginx-service.yaml
│   ├── gatewayclass.yaml
│   ├── gateway.yaml
│   └── httproute.yaml
├── monitoring/
│   ├── prometheus-config.yaml
│   ├── prometheus-deployment.yaml
│   └── prometheus-service.yaml
├── logging/
│   ├── filebeat-rbac.yaml
│   ├── filebeat-config.yaml
│   └── filebeat-daemonset.yaml
├── .gitignore
└── README.md
```

## Запуск одной командой

```bash
git clone https://github.com/Saigafarova/devops-hack.git
cd devops-hack
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

Скрипт разворачивает всё с нуля, если уже что-то установлено, то пропускает это.

## Требования к среде

- **ОС:** Ubuntu 24.04 (тестировалось в GitHub Codespaces).
- **Docker:** 20+.
- **kind:** v0.33.0.
- **kubectl:** v1.37.0.
- **Helm:** v3.
- **Свободные порты:** 31100 (NodePort).
- **Свободное место:** 15 ГБ.

## Порты

- NodePort для Gateway — назначается автоматически (диапазон 30000–32767). Узнать: `kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=my-gateway`.
- `9090` — Prometheus UI (через `kubectl port-forward`).
- `80` — порт Nginx внутри кластера.

## Зависимости

| Компонент | Версия |
|---|---|
| Kubernetes | v1.37.0 |
| kind | v0.33.0 |
| kubectl | v1.37.0 |
| Gateway API CRD | v1.6.1 |
| Envoy Gateway | v1.9.2 |
| Nginx | 1.27 |
| Prometheus | v2.54.1 |
| Filebeat | 8.15.0 |

## Внешние сервисы

- **Docker Hub** — источник образов (nginx, envoy, prometheus, filebeat).
- **GitHub** — хостинг репозитория.
- **Внешних платных сервисов нет.**

## Работа с данными

- **Nginx** — пишет access-логи в stdout пода.
- **Filebeat** — читает логи из `/var/log/containers/*.log` на каждой ноде (DaemonSet).
- **Prometheus** — собирает метрики с Envoy Gateway (`envoy-gateway.envoy-gateway-system.svc:19001`).

## Тестовые данные

Специальных тестовых данных не нужно. После развёртывания приложение сразу доступно.

## Как проверить по шагам

### 1. Проверить статус

```bash
kubectl get pods -A
kubectl get gateway
kubectl get httproute
```

Ожидаемо:
- Все поды `Running`.
- `Gateway my-gateway` — `PROGRAMMED: True`.
- `HTTPRoute nginx-route` — создан.

### 2. Проверить доступ к приложению

```bash
kubectl get nodes -o wide
kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=my-gateway
```

Узнать NodePort:

```
NODEPORT=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=my-gateway \
  -o jsonpath='{.items[0].spec.ports[0].nodePort}')
```

Узнать IP ноды:

```
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
```

Проверить доступ:

```
kubectl run test-curl --rm -it \
  --image=busybox --restart=Never \
  --image-pull-policy=IfNotPresent \
  -- wget -qO- http://${NODE_IP}:${NODEPORT}/
```

Ожидаемо: HTML-страница «Welcome to nginx!».

### 3. Проверить мониторинг

```bash
kubectl port-forward svc/prometheus-service 9090:9090
```

Открыть `http://localhost:9090`.

Запрос `up` — оба таргета должны быть `1`.

Запрос `controller_runtime_reconcile_errors_total` — счётчик ошибок (0).

### 4. Проверить логирование

```bash
kubectl logs -l app=filebeat --tail=20
```

Ожидаемо: access-логи Nginx в JSON.

## Ожидаемое поведение

- `./scripts/deploy.sh` создаёт всё с нуля одной командой.
- Повторный запуск не ломает систему.
- Gateway `my-gateway` доступен через NodePort.
- Prometheus собирает метрики с Envoy Gateway.
- Filebeat собирает access-логи Nginx.

## Известные ограничения

1. kind не поддерживает LoadBalancer — сервис Gateway переведён на NodePort.
2. Нет интернета внутри kind-нод — образы загружаются через `docker save | ctr import`.
3. Envoy Gateway с digest — обходится через EnvoyProxy с указанием тега.
4. Один кластер — не тестировалось на multi-node.
5. Тестировалось только в Codespaces — на VDS может отличаться.

## Остановка и повторный запуск

**Остановить:**
```bash
kind delete cluster --name devops
```

**Запустить заново:**
```bash
./scripts/deploy.sh
```

## Источники

- [Kubernetes](https://kubernetes.io/docs/)
- [kind](https://kind.sigs.k8s.io/)
- [Gateway API](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway](https://gateway.envoyproxy.io/)
- [Prometheus](https://prometheus.io/docs/)
- [Filebeat](https://www.elastic.co/beats/filebeat)