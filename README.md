# logs_for_k8s

Репозиторий: https://github.com/NAGenaev/k8s-log-collector

Jenkins-пайплайн для выгрузки логов подов деплоймента из произвольного набора k8s-кластеров/неймспейсов (георезервирование + шардирование): один неймспейс одного кластера, зеркальные неймспейсы обоих кластеров, или вообще все неймспейсы, где есть деплоймент.

## Как это работает

1. `Jenkinsfile` читает `config/clusters.yaml`, пересекает выбранные пользователем кластеры/неймспейсы (чекбоксы-параметры) с реальным списком неймспейсов на кластере — получает список валидных пар `(cluster, namespace)`.
2. Для каждой пары параллельно: тянет свой k8s deploy-токен из Jenkins Credentials, собирает одноразовый kubeconfig, находит поды деплоймента по `spec.selector.matchLabels`, забирает `kubectl logs` для каждого пода/контейнера (+ `--previous` при рестартах), считает `ERROR`/`WARN` и заливает такие строки фоном (красным/жёлтым) через ANSI-эскейпы. Каждая ветка печатает короткие статусные строки вида `[cluster/namespace] pod/container: ERROR=n WARN=m` — без потока служебной трассировки шелла.
3. После завершения всех веток — сводный отчёт: сначала общая статистика и разбивка по подам, затем сами логи отдельным блоком на каждый под/контейнер с счётчиками ERROR/WARN прямо в заголовке блока.

## Предпосылки

- Jenkins-агент с лейблом `k8s-tools`: `bash`, `kubectl`, `jq`, `base64`.
- Плагины: **AnsiColor**, **Pipeline Utility Steps** (`readYaml`/`readJSON`/`writeJSON`), **Timestamper** (шаг `timestamps()`).
- Job типа "Pipeline script from SCM" на этот репозиторий.

## Схема `config/clusters.yaml`

```yaml
clusters:
  - name: dc1
    apiServer: https://k8s-dc1.example.com:6443
    insecureSkipTlsVerify: false      # только для лабы/self-signed; в проде — caCertBase64
    caCertBase64: ""                  # base64(PEM) CA-сертификата кластера (не секрет, публичный ключ)
    namespaces: [shard-01, shard-02, shard-03]
```

`caCertBase64` приоритетнее `insecureSkipTlsVerify`, если задан. Для боевых кластеров нужно указывать именно его — `insecureSkipTlsVerify: true` предназначен только для тестовых окружений с self-signed сертификатами (как в minikube).

## Настройка credentials

На каждую пару (кластер, неймспейс) — отдельный Jenkins credential типа **Secret text** с ID `k8s-token-<cluster>-<namespace>`, содержащий токен ServiceAccount с правами на чтение логов в этом неймспейсе (например `get`/`list` на `pods`, `get` на `deployments`, `get` на `pods/log`).

Пример для `config/clusters.yaml` из репозитория: `k8s-token-dc1-shard-01`, `k8s-token-dc1-shard-02`, `k8s-token-dc1-shard-03`, `k8s-token-dc2-shard-01`, `k8s-token-dc2-shard-02`, `k8s-token-dc2-shard-04`.

## Как добавить кластер или неймспейс

1. Добавить запись в `config/clusters.yaml` (кластер целиком, либо неймспейс в список существующего кластера).
2. Добавить соответствующий `booleanParam` в `Jenkinsfile` (и обработку в `Validate & Resolve`).
3. Создать credential `k8s-token-<cluster>-<namespace>`.
4. **Важно**: для job "Pipeline script from SCM" Jenkins показывает параметры от предыдущего успешного/завершённого билда — новый чекбокс появится в форме "Build with Parameters" только после одного прогона с обновлённым Jenkinsfile.

## Параметры билда

| Параметр | Назначение |
|---|---|
| `DEPLOYMENT_NAME` | Имя деплоймента (обязательно) |
| `CLUSTER_DC1`, `CLUSTER_DC2` | Какие кластеры включить |
| `NS_SHARD_01`..`NS_SHARD_04` | Какие неймспейсы включить (пара кластер×неймспейс валидна, только если неймспейс реально есть в конфиге этого кластера) |
| `INCLUDE_PREVIOUS_LOGS` | Дополнительно тянуть `kubectl logs --previous` для контейнеров с рестартами |
| `LOG_LEVELS` | `WARN_ERROR` (по умолчанию) — в логе только строки ERROR/WARN; `ALL` — дополнительно печатать INFO/прочие строки без подсветки |
| `SINCE` | `kubectl logs --since` (ограничение объёма) |
| `TAIL_LINES` | `kubectl logs --tail` на контейнер (ограничение объёма) |

## Обработка ошибок

Отсутствие креда, недоступный кластер, деплоймент не найден, пустой список подов, отсутствие `--previous`-логов — не валят билд целиком, а помечаются как skip по конкретной паре, билд получает статус `UNSTABLE`. `FAILURE` — только если вообще ни одна из выбранных пар не дала данных.

## Известные ограничения

- Поддерживаются только деплойменты с `spec.selector.matchLabels` (без `matchExpressions`).
- `ERROR`/`WARN` ищутся как подстрока (`index()`), не через regex — простая и предсказуемая логика для произвольного содержимого логов. Паттерны настраиваются через `ERROR_PATTERN`/`WARN_PATTERN` в `scripts/lib.sh`.
- Список кластеров/неймспейсов в параметрах Jenkinsfile синхронизируется с `config/clusters.yaml` вручную. При заметном росте числа неймспейсов — переход на плагин Extended Choice Parameter (`PT_CHECKBOX`) вместо набора отдельных `booleanParam`.
