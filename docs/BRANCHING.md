# Стратегия ветвления (Branching Strategy)

В проекте используется упрощённый вариант **GitFlow** с упором на CI/CD-автоматизацию.

## Ветки

```
                  ┌──────────────────────────────────────────────────────────────┐
                  │                         main (production)                    │
                  └──────────────────────────────────────────────────────────────┘
                              ▲                          ▲                    ▲
                              │ merge                    │ merge              │ merge (fast-track)
                              │                          │                    │
                  ┌───────────┴────────┐      ┌──────────┴─────────┐   ┌──────┴──────────┐
                  │      develop        │      │   release/v2.5.1   │   │  hotfix/*        │
                  │   (staging env)    │      │   (RC preparation) │   │  (prod fix)     │
                  └─────────────────────┘      └────────────────────┘   └──────────────────┘
                       ▲      ▲      ▲
                       │      │      │  merge after PR review
                  ┌────┴──┐┌───┴──┐┌───┴────┐
                  │feat/  ││feat/ ││feat/   │
                  │graph  ││auth  ││s3      │
                  └───────┘└──────┘└────────┘
```

## Правила

### `main`

- **Цель:** всегда готовый к production код.
- **CI:** полный пайплайн, образ тегируется `latest` + semver.
- **CD:** автодеплой в **production**.
- **Защита:** branch protection required reviews (≥1), required status checks (CI must pass), no force push.
- **Теги:** на `main` ставятся semver-теги (`v2.5.0`, `v2.5.1`) через GitHub Releases.

### `develop`

- **Цель:** интеграционная ветка, где собираются слитые фичи.
- **CI:** полный пайплайн.
- **CD:** автодеплой в **staging**.
- **Источник:** merge из `feature/*` после одобрения PR.

### `feature/*`

- **Цель:** разработка новой функциональности.
- **CI:** запускается на PR в `develop` или `main` (lint + tests + build без push в registry).
- **CD:** ❌ — нет.
- **Жизненный цикл:** короткий, удаляется после merge.

### `release/*`

- **Цель:** подготовка production-релиза (заморозка фич, только bugfix).
- **CI:** полный.
- **CD:** автодеплой в staging с тегом `release-<version>`.
- **Создаётся:** от `develop` в момент, когда решено релизить.
- **Закрывается:** merge в `main` (с тегом) + backport в `develop`.

### `hotfix/*`

- **Цель:** срочный фикс критической проблемы в production.
- **CI:** полный.
- **CD:** fast-track в production (минуя develop).
- **Создаётся:** от `main`.
- **Закрывается:** merge в `main` + backport в `develop`.

## Семантика версионирования (SemVer)

```
v2.5.1
  │ │ │
  │ │ └─ PATCH  — bugfix, hotfix (обратная совместимость)
  │ └─── MINOR  — новая фича (обратная совместимость)
  └───── MAJOR  — breaking change
```

CI берёт версию из git-тега через `docker/metadata-action`:

```yaml
tags: |
  type=semver,pattern={{version}}        # v2.5.1 → 2.5.1
  type=semver,pattern={{major}}.{{minor}} # → 2.5
  type=sha,prefix=sha-,format=short       # → sha-abc1234
  type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}
```

## Карта запуска workflow по веткам

| Ветка              | `ci.yml` | `cd.yml` (env)        | `e2e.yml`  | `performance.yml` |
|--------------------|----------|------------------------|------------|-------------------|
| `main`             | ✅ push   | ✅ production          | nightly    | post-CD           |
| `develop`          | ✅ push   | ✅ staging             | nightly    | nightly           |
| `release/*`        | ✅ push   | ✅ staging (tagged)    | manual     | manual            |
| `hotfix/*`         | ✅ push   | ✅ production          | manual     | manual            |
| `feature/*` (PR)   | ✅ PR     | ❌                     | ❌          | ❌                 |
| `bugfix/*` (PR)    | ✅ PR     | ❌                     | ❌          | ❌                 |

## Пример жизненного цикла фичи

```bash
# 1. Создать ветку от develop
git checkout develop
git pull
git checkout -b feature/upload-s3

# 2. Работать, коммитить
git add ... && git commit -m "feat(upload): add S3 storage backend"

# 3. Открыть PR в develop
gh pr create --base develop --head feature/upload-s3

# 4. CI на PR проверяет: lint, security, build (без push)

# 5. После review — squash & merge → develop
#    → CI запускается на develop (с пушем образа в GHCR)
#    → CD разворачивает в staging

# 6. Когда готов релиз:
git checkout develop
git checkout -b release/v2.5.1
# bugfix'ы здесь → тег v2.5.1 на main → CD в production
```
