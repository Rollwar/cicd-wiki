# Архитектура

## Двухрепозитарная модель

```
┌────────────────────────────────┐        ┌────────────────────────────────────┐
│  github.com/Rollwar/wiki-v2    │        │  github.com/Rollwar/cicd-wikijs    │
│  (app repo)                    │        │  (pipeline repo)                   │
│                                │        │                                    │
│  server.js                     │ calls  │  .github/workflows/                │
│  server/ (app source)          │ ─────► │    ci.yml                          │
│  Dockerfile                    │        │    cd.yml                          │
│  package.json                  │        │    e2e.yml                         │
│  .github/workflows/ci-app.yml  │        │    performance.yml                 │
│    (1 job: workflow_call)      │        │    rollback.yml                    │
└────────────────────────────────┘        │  deploy/k8s/*.yaml                 │
                                          │  scripts/*.sh                     │
                                          │  tests/e2e, tests/performance      │
                                          │  demo/ (dry-run)                   │
                                          └────────────────────────────────────┘
                                                          │
                                                          │ kubectl apply
                                                          ▼
                                          ┌────────────────────────────────────┐
                                          │  k3s cluster                       │
                                          │                                    │
                                          │  ns: wiki-staging                  │
                                          │  ns: wiki-production               │
                                          │                                    │
                                          │  Deployment wiki-blue  (3 replicas) │
                                          │  Deployment wiki-green (3 replicas) │
                                          │  StatefulSet postgres (1 replica)  │
                                          │  Service wiki (live, slot=blue)    │
                                          │  Service wiki-preview (slot=green) │
                                          │  PVC postgres-pvc, uploads-pvc     │
                                          │  Ingress wiki.local → svc wiki     │
                                          └────────────────────────────────────┘
                                                          │
                                                          │ slack webhook
                                                          ▼
                                          ┌────────────────────────────────────┐
                                          │  Slack #cicd-alerts                │
                                          │  (success / fail / rollback)       │
                                          └────────────────────────────────────┘
```

## Слои приложения Wiki.js

| Слой            | Технология                                  | Роль                                   |
|-----------------|---------------------------------------------|----------------------------------------|
| Runtime         | Node.js 20-alpine                           | процесс приложения                    |
| Web framework  | Express 4                                   | HTTP routing, middleware              |
| ORM             | Sequelize 6                                 | доступ к PostgreSQL                    |
| Database        | PostgreSQL 15-alpine (StatefulSet)         | хранение страниц, пользователей, прав |
| Файловое хранилище | PVC `wiki-uploads-pvc` (local-path)     | загруженные пользователями файлы        |
| Health checks   | `/health/live`, `/health/ready`            | Kubernetes liveness/readiness probes   |
| Логирование     | winston (JSON в prod, colorize в dev)       | structured logging                    |

## Безопасность

| Аспект                       | Реализация                                                       |
|------------------------------|------------------------------------------------------------------|
| Non-root контейнер           | UID 1001, `runAsNonRoot: true` в securityContext                |
| Capabilities drop            | `capabilities.drop: [ALL]`                                      |
| No privilege escalation      | `allowPrivilegeEscalation: false`                               |
| Pod Security Standards       | namespace label `pod-security.kubernetes.io/enforce: baseline` |
| Image signing                | cosign keyless signing на main-ветке                             |
| Vulnerability scanning       | Trivy fs scan + npm audit (HIGH+) в CI                          |
| Secret management (prod)     | рекомендация: SealedSecret / external-secrets-operator          |

## Observability (рекомендуемое расширение)

- **Metrics:** wiki.js + postgres-exporter → Prometheus → Grafana dashboards.
- **Logs:** stdout JSON-логи → Loki / CloudWatch.
- **Tracing:** OpenTelemetry SDK в Express → Jaeger / Tempo.
- **Alerting:** Alertmanager → triggers `repository_dispatch` для auto-rollback.

В рамках текущей demo-версии observability ограничена:
- health-эндпоинты + post-deploy-monitor
- Slack-уведомления на каждый шаг пайплайна
