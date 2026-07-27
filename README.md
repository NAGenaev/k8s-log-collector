# logs_for_k8s

Репозиторий: https://github.com/NAGenaev/k8s-log-collector

Jenkins-пайплайн для выгрузки логов подов деплоймента из произвольного набора k8s-кластеров/неймспейсов (георезервирование + шардирование): один неймспейс одного кластера, зеркальные неймспейсы обоих кластеров, или вообще все неймспейсы, где есть деплоймент.

Инструкция по разворачиванию в проде: [DEPLOYMENT.md](DEPLOYMENT.md).

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
  - name: pk2-ppsa01
    apiServer: https://k8s-pk2-ppsa01.example.com:6443
    insecureSkipTlsVerify: false      # только для лабы/self-signed; в проде — caCertBase64
    caCertBase64: ""                  # base64(PEM) CA-сертификата кластера (не секрет, публичный ключ)
    namespaceSuffixes: [ppsa-central, ppsa-master01, ppsa-master02, ppsa-simple]
```

Реальное имя неймспейса — `<cluster>-<suffix>`, например `pk2-ppsa01-ppsa-central`. `caCertBase64` приоритетнее `insecureSkipTlsVerify`, если задан. Для боевых кластеров нужно указывать именно его — `insecureSkipTlsVerify: true` предназначен только для тестовых окружений с self-signed сертификатами (как в minikube).

## Настройка credentials

На каждую пару (кластер, неймспейс) — отдельный Jenkins credential типа **Secret text** с ID `token_<namespace>` (полное имя неймспейса, включая префикс кластера), содержащий токен ServiceAccount с правами на чтение логов в этом неймспейсе (например `get`/`list` на `pods`, `get` на `deployments`, `get` на `pods/log`).

Пример для `config/clusters.yaml` из репозитория: `token_pk2-ppsa01-ppsa-central`, `token_pk2-ppsa01-ppsa-master01`, `token_pk2-ppsa01-ppsa-master02`, `token_pk2-ppsa01-ppsa-simple`, и аналогично 4 штуки для `pk5-ppsa01`.

## Как добавить кластер или неймспейс

1. Добавить запись в `config/clusters.yaml` (кластер целиком, либо суффикс неймспейса в список существующего кластера).
2. Добавить соответствующий `booleanParam` в `Jenkinsfile` (и обработку в `Validate & Resolve`).
3. Создать credential `token_<cluster>-<suffix>` (полное имя неймспейса).
4. **Важно**: для job "Pipeline script from SCM" Jenkins показывает параметры от предыдущего успешного/завершённого билда — новый чекбокс появится в форме "Build with Parameters" только после одного прогона с обновлённым Jenkinsfile.

## Параметры билда

| Параметр | Назначение |
|---|---|
| `DEPLOYMENT_NAME` | Имя деплоймента (обязательно) |
| `CLUSTER_PK2`, `CLUSTER_PK5` | Какие кластеры включить (pk2-ppsa01 / pk5-ppsa01) |
| `NS_CENTRAL`, `NS_MASTER01`, `NS_MASTER02`, `NS_SIMPLE` | Какие суффиксы неймспейсов включить (пара кластер×суффикс валидна, только если суффикс реально есть в конфиге этого кластера) |
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
