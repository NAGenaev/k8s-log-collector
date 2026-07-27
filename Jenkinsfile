pipeline {
    agent { label 'k8s-tools' }

    options {
        timestamps()
        ansiColor('xterm')
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
        skipDefaultCheckout()
    }

    parameters {
        string(name: 'DEPLOYMENT_NAME', defaultValue: '', description: 'Deployment to pull logs for (required)')
        booleanParam(name: 'CLUSTER_DC1', defaultValue: false, description: 'Cluster: dc1')
        booleanParam(name: 'CLUSTER_DC2', defaultValue: false, description: 'Cluster: dc2')
        booleanParam(name: 'NS_SHARD_01', defaultValue: false, description: 'Namespace: shard-01')
        booleanParam(name: 'NS_SHARD_02', defaultValue: false, description: 'Namespace: shard-02')
        booleanParam(name: 'NS_SHARD_03', defaultValue: false, description: 'Namespace: shard-03')
        booleanParam(name: 'NS_SHARD_04', defaultValue: false, description: 'Namespace: shard-04')
        booleanParam(name: 'INCLUDE_PREVIOUS_LOGS', defaultValue: true, description: 'Fetch --previous logs too (for restarted containers)')
        choice(name: 'LOG_LEVELS', choices: ['WARN_ERROR', 'ALL'], description: 'WARN_ERROR = only WARN/ERROR lines in the log output; ALL = also include INFO/other lines')
        string(name: 'SINCE', defaultValue: '1h', description: 'kubectl logs --since')
        string(name: 'TAIL_LINES', defaultValue: '5000', description: 'kubectl logs --tail per container')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'rm -rf logs-out'
            }
        }

        stage('Validate & Resolve') {
            steps {
                script {
                    if (!params.DEPLOYMENT_NAME?.trim()) {
                        error "DEPLOYMENT_NAME is required"
                    }
                    def cfg = readYaml file: 'config/clusters.yaml'

                    def selectedClusters = []
                    if (params.CLUSTER_DC1) selectedClusters << 'dc1'
                    if (params.CLUSTER_DC2) selectedClusters << 'dc2'

                    def selectedNs = []
                    if (params.NS_SHARD_01) selectedNs << 'shard-01'
                    if (params.NS_SHARD_02) selectedNs << 'shard-02'
                    if (params.NS_SHARD_03) selectedNs << 'shard-03'
                    if (params.NS_SHARD_04) selectedNs << 'shard-04'

                    if (!selectedClusters || !selectedNs) {
                        error "Select at least one cluster and one namespace"
                    }

                    def pairs = []
                    cfg.clusters.each { c ->
                        if (!selectedClusters.contains(c.name)) return
                        c.namespaces.each { ns ->
                            if (selectedNs.contains(ns)) {
                                pairs << [cluster  : c.name,
                                          namespace: ns,
                                          apiServer: c.apiServer,
                                          insecure : (c.insecureSkipTlsVerify ?: false).toString(),
                                          caCert   : (c.caCertBase64 ?: '')]
                            }
                        }
                    }
                    if (!pairs) {
                        error "No valid (cluster, namespace) pairs for this selection — check config/clusters.yaml"
                    }

                    echo "Resolved pairs:\n" + pairs.collect { "  - ${it.cluster}/${it.namespace}" }.join('\n')
                    env.PAIRS_JSON = writeJSON returnText: true, json: pairs
                }
            }
        }

        stage('Fetch logs') {
            steps {
                script {
                    def pairs = readJSON text: env.PAIRS_JSON
                    def branches = [:]
                    pairs.each { p ->
                        branches["${p.cluster}/${p.namespace}"] = { fetchAndProcess(p) }
                    }
                    parallel branches
                }
            }
        }

        stage('Report') {
            steps {
                script { generateReport() }
            }
        }
    }
}

def fetchAndProcess(Map p) {
    def dir = "logs-out/${p.cluster}__${p.namespace}"
    sh "mkdir -p '${dir}'"
    try {
        withCredentials([string(credentialsId: "k8s-token-${p.cluster}-${p.namespace}", variable: 'K8S_TOKEN')]) {
            withEnv([
                "API_SERVER=${p.apiServer}", "INSECURE=${p.insecure}", "CA_CERT_B64=${p.caCert}",
                "CLUSTER=${p.cluster}", "NAMESPACE=${p.namespace}",
                "DEPLOY=${params.DEPLOYMENT_NAME}", "SINCE=${params.SINCE}",
                "TAIL_LINES=${params.TAIL_LINES}", "INCLUDE_PREVIOUS=${params.INCLUDE_PREVIOUS_LOGS}",
                "LOG_LEVELS=${params.LOG_LEVELS}", "OUT_DIR=${dir}"
            ]) {
                sh label: "fetch ${p.cluster}/${p.namespace}", script: '''
                    set -uo pipefail
                    set +x
                    . scripts/lib.sh
                    run_pair
                '''
            }
        }
    } catch (err) {
        echo "WARNING: skipping ${p.cluster}/${p.namespace}: ${err.getMessage()}"
        writeFile file: "${dir}/.skip", text: "reason=credential-or-error: ${err.getMessage()}\n"
    }
}

def generateReport() {
    def statsFiles = findFiles(glob: 'logs-out/**/*.stats')
    def skipFiles  = findFiles(glob: 'logs-out/**/.skip')
    def divider = '================================================================'
    def GREEN = "[1;30;42m"
    def RED   = "[1;31m"
    def YEL   = "[1;33m"
    def RST   = "[0m"

    def totalErr = 0, totalWarn = 0
    def byPod = [:]
    def statsByLabel = [:]
    statsFiles.each { f ->
        def props = readProperties file: f.path
        int err = (props.ERROR ?: '0') as int
        int warn = (props.WARN ?: '0') as int
        totalErr += err; totalWarn += warn
        def label = f.path.replace('logs-out/', '').replace('.stats', '')
        statsByLabel[label] = [err, warn]
        def podKey = label.replaceAll(/__previous$/, '').replaceAll(/__[^_]+$/, '')
        def acc = byPod.getOrDefault(podKey, [0, 0])
        byPod[podKey] = [acc[0] + err, acc[1] + warn]
    }

    // Everything below is batched into two echo calls total (summary, then
    // logs) so the console isn't padded out with one Jenkins step marker
    // per line — only the actual data is worth a line here.
    def summary = []
    summary << divider
    summary << "SUMMARY: ${statsFiles.length} pod/container log(s) collected"
    summary << "TOTAL ${RED}ERROR=${totalErr}${RST}   ${YEL}WARN=${totalWarn}${RST}"
    summary << divider
    summary << 'Per-pod breakdown:'
    byPod.each { k, v -> summary << "  ${GREEN}${k}${RST}   ${RED}ERROR=${v[0]}${RST}   ${YEL}WARN=${v[1]}${RST}" }

    if (skipFiles) {
        summary << divider
        summary << 'SKIPPED (no data collected for these pairs):'
        skipFiles.each { f -> summary << "  ${GREEN}${f.path.replace('/.skip', '')}${RST}: ${readFile(f.path).trim()}" }
        currentBuild.result = 'UNSTABLE'
    }
    summary << divider
    echo summary.join('\n')

    def logLines = []
    findFiles(glob: 'logs-out/**/*.color.log').each { f ->
        def label = f.path.replace('logs-out/', '').replace('.color.log', '')
        def counts = statsByLabel[label] ?: [0, 0]
        logLines << "\n---- ${GREEN}${label}${RST}   (${RED}ERROR=${counts[0]}${RST} ${YEL}WARN=${counts[1]}${RST}) ----"
        // NB: String.trim() strips control chars (code point <= 0x20), which would eat the
        // leading ESC (0x1B) of a highlighted first line — strip only the trailing newline instead.
        logLines << readFile(f.path).replaceAll('[\\r\\n]+$', '')
    }
    if (logLines) {
        echo logLines.join('\n')
    }

    if (statsFiles.length == 0) {
        error "No log data collected for any selected pair"
    }
}
