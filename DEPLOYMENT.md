# Разворачивание в проде

Пошаговая инструкция для тех, кто настраивает `k8s-log-collector` на реальном Jenkins против реальных k8s-кластеров (georedundant "плечи" + шардирование по неймспейсам).

## 0. Что нужно заранее

- Jenkins-контроллер или отдельный агент с лейблом **`k8s-tools`**.
- На этом агенте установлены: `bash`, `kubectl`, `jq`, `base64`, `git`. Все должны быть в `PATH`.
- Сетевая доступность с агента до API-серверов всех кластеров, логи которых нужно собирать (обычные `:6443`/`:443`, как для любого `kubectl`).
- Права администратора в Jenkins (для установки плагинов и credentials) и `kubectl`-доступ с правами на создание RBAC-объектов в каждом целевом кластере/неймспейсе.

## 1. Плагины Jenkins

Через **Manage Jenkins → Plugins** установить (если ещё не стоят):

- **AnsiColor** — подсветка ERROR/WARN в консоли.
- **Pipeline Utility Steps** — `readYaml`/`readJSON`/`writeJSON`.
- **Timestamper** — шаг `timestamps()`.
- **Git** и **Pipeline** (обычно уже есть в стандартной сборке Jenkins).
- Credentials Binding идёт в комплекте с ядром — отдельно ставить не нужно.

## 2. RBAC и токен в каждом (кластер, неймспейс)

Для каждой пары (кластер, неймспейс), логи которой нужно собирать, — отдельный `ServiceAccount` с минимальными правами и статический (не истекающий) токен. Ротация не нужна: токен создаётся один раз через `Secret` типа `kubernetes.io/service-account-token`, а не через `kubectl create token` (тот выдаёт короткоживущий токен и не подходит).

Сохраните как `rbac.yaml` и примените в каждый нужный неймспейс:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: log-reader
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: log-reader
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: log-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: log-reader
subjects:
  - kind: ServiceAccount
    name: log-reader
---
apiVersion: v1
kind: Secret
metadata:
  name: log-reader-token
  annotations:
    kubernetes.io/service-account.name: log-reader
type: kubernetes.io/service-account-token
```

```bash
kubectl --context <cluster-context> -n <namespace> apply -f rbac.yaml
```

Достать сам токен (после применения манифеста контроллер k8s заполняет `Secret` не мгновенно — если `token` пуст, подождать пару секунд и повторить):

```bash
kubectl --context <cluster-context> -n <namespace> \
  get secret log-reader-token -o jsonpath='{.data.token}' | base64 -d
```

Повторить для каждой (кластер, неймспейс) пары, которую нужно опрашивать.

## 3. CA-сертификат каждого кластера

Для боевых кластеров **не использовать** `insecureSkipTlsVerify: true` — это только для лабораторных self-signed окружений. Нужен CA-сертификат кластера в base64, который кладётся прямо в `config/clusters.yaml` (это публичные данные, не секрет).

Если под рукой есть валидный kubeconfig с доступом к кластеру:

```bash
kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="<cluster-name>")].cluster.certificate-authority-data}'
```

Это уже готовая base64-строка (kubeconfig и так хранит CA в base64) — просто скопировать значение как есть.

Если CA выдают отдельным `.crt`-файлом:

```bash
base64 -w0 ca.crt
```

## 4. `config/clusters.yaml`

Реальное имя неймспейса собирается как `<cluster>-<suffix>` (например `pk2-ppsa01-ppsa-central`), поэтому в конфиге хранятся именно суффиксы, а не полные имена:

```yaml
clusters:
  - name: pk2-ppsa01
    apiServer: https://<api-server-pk2-ppsa01>:6443
    insecureSkipTlsVerify: false
    caCertBase64: "<base64 CA-сертификата pk2-ppsa01>"
    namespaceSuffixes: [ppsa-central, ppsa-master01, ppsa-master02, ppsa-simple]
  - name: pk5-ppsa01
    apiServer: https://<api-server-pk5-ppsa01>:6443
    insecureSkipTlsVerify: false
    caCertBase64: "<base64 CA-сертификата pk5-ppsa01>"
    namespaceSuffixes: [ppsa-central, ppsa-master01, ppsa-master02, ppsa-simple]
```

`namespaceSuffixes` — только те суффиксы, где реально нужно искать логи (и где применён RBAC из шага 2). Список кластеров/суффиксов в этом файле — источник истины, с которым сверяются чекбоксы параметров билда.

Если набор кластеров/суффиксов отличается от заготовки в репозитории (`pk2-ppsa01`/`pk5-ppsa01`, `ppsa-central/master01/master02/simple`) — нужно также поправить `booleanParam`-ы и логику в `Validate & Resolve` в `Jenkinsfile` (см. раздел "Как добавить кластер/неймспейс" в `README.md`).

Закоммитить и запушить `config/clusters.yaml` в ветку, на которую будет смотреть Jenkins job.

## 5. Credentials в Jenkins

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials**, тип **Secret text**, для каждой пары (кластер, неймспейс) из `config/clusters.yaml`:

- ID: `token_<полное имя неймспейса>` (например `token_pk2-ppsa01-ppsa-central`) — должно **точно** совпадать с этим шаблоном (namespace = cluster + "-" + suffix), ID вычисляется в Jenkinsfile автоматически как `token_${cluster}-${suffix}`.
- Secret: токен, полученный на шаге 2.

Ничего кроме токена в credential не хранится — endpoint и CA берутся из `config/clusters.yaml`.

## 6. Job в Jenkins

**New Item → Pipeline**:

- **Pipeline → Definition**: *Pipeline script from SCM*.
- **SCM**: Git, URL репозитория (`https://github.com/NAGenaev/k8s-log-collector.git` или внутреннее зеркало), ветка — та, куда запушен готовый `config/clusters.yaml` (обычно `main`/`master`).
- **Script Path**: `Jenkinsfile` (по умолчанию).

## 7. Первый запуск

Jenkins для job-ов "Pipeline script from SCM" показывает параметры сборки от **предыдущего** запуска, а не от только что закоммиченного `Jenkinsfile`. Поэтому:

1. Первый раз запустить job **без параметров** (кнопка "Build Now") — этот билд, скорее всего, упадёт с ошибкой `DEPLOYMENT_NAME is required`, это ожидаемо.
2. После него в форме "Build with Parameters" появятся все чекбоксы и поля.
3. Дальше запускать уже с реальными параметрами.

То же самое повторяется при любом добавлении нового кластера/неймспейса (новый `booleanParam` в `Jenkinsfile`) — нужен один "пустой" прогон, чтобы Jenkins перечитал форму.

## 8. Проверка

1. Запустить с одной парой (один кластер, один неймспейс, реальный `DEPLOYMENT_NAME`) — убедиться, что билд зелёный, в выводе есть `SUMMARY`/`TOTAL` и цветные (заливка фоном) строки ERROR/WARN.
2. Запустить с несколькими неймспейсами сразу (в т.ч. на обоих кластерах) — проверить, что резолвятся именно те пары, где неймспейс реально числится в `config/clusters.yaml`, и что параллельные ветки не путают данные между собой.
3. Специально указать несуществующий `DEPLOYMENT_NAME` или неймспейс без деплоймента — билд должен стать `UNSTABLE` (не `FAILURE`), с пометкой `SKIPPED` в отчёте.
4. Проверить `LOG_LEVELS=ALL` — в логе должны появиться INFO-строки без подсветки вперемешку с подсвеченными ERROR/WARN.

## 9. Безопасность и эксплуатация

- Токены `ServiceAccount` хранятся только в Jenkins Credentials (замаскированы в логах через `withCredentials`), нигде больше не сохраняются и не пишутся в файлы репозитория.
- Права `log-reader` роли — только чтение (`get`/`list` на `pods`, `get` на `pods/log` и `deployments`), никакого доступа на запись.
- `SINCE`/`TAIL_LINES` по умолчанию ограничивают объём вытягиваемых логов — стоит держать разумные значения, чтобы не утащить гигабайты за один прогон.
- При компрометации токена — удалить `Secret`/`ServiceAccount` в кластере и создать заново (шаг 2), обновить credential в Jenkins.

## 10. Известные ограничения

См. раздел "Известные ограничения" в `README.md` — деплойменты только с `spec.selector.matchLabels`, ERROR/WARN ищутся подстрокой, список кластеров/неймспейсов в параметрах Jenkinsfile синхронизируется с конфигом вручную.
