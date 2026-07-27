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
        booleanParam(name: 'CLUSTER_PK2', defaultValue: false, description: 'Cluster: pk2-ppsa01')
        booleanParam(name: 'CLUSTER_PK5', defaultValue: false, description: 'Cluster: pk5-ppsa01')
        booleanParam(name: 'NS_CENTRAL', defaultValue: false, description: 'Namespace suffix: ppsa-central')
        booleanParam(name: 'NS_MASTER01', defaultValue: false, description: 'Namespace suffix: ppsa-master01')
        booleanParam(name: 'NS_MASTER02', defaultValue: false, description: 'Namespace suffix: ppsa-master02')
        booleanParam(name: 'NS_SIMPLE', defaultValue: false, description: 'Namespace suffix: ppsa-simple')
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
                    if (params.CLUSTER_PK2) selectedClusters << 'pk2-ppsa01'
                    if (params.CLUSTER_PK5) selectedClusters << 'pk5-ppsa01'

                    def selectedSuffixes = []
                    if (params.NS_CENTRAL) selectedSuffixes << 'ppsa-central'
                    if (params.NS_MASTER01) selectedSuffixes << 'ppsa-master01'
                    if (params.NS_MASTER02) selectedSuffixes << 'ppsa-master02'
                    if (params.NS_SIMPLE) selectedSuffixes << 'ppsa-simple'

                    if (!selectedClusters || !selectedSuffixes) {
                        error "Select at least one cluster and one namespace"
                    }

                    // Real namespace name is "<cluster>-<suffix>" (e.g. pk2-ppsa01-ppsa-central),
                    // and the matching Jenkins credential ID is "token_<that full namespace name>".
                    def pairs = []
                    cfg.clusters.each { c ->
                        if (!selectedClusters.contains(c.name)) return
                        c.namespaceSuffixes.each { suf ->
                            if (selectedSuffixes.contains(suf)) {
                                pairs << [cluster  : c.name,
                                          namespace: "${c.name}-${suf}",
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
                script {
                    int rc = sh(label: 'report', returnStatus: true, script: '''
                        set -uo pipefail
                        set +x
                        . scripts/lib.sh
                        print_report
                    ''')
                    if (rc == 1) {
                        error "No log data collected for any selected pair"
                    } else if (rc == 2) {
                        currentBuild.result = 'UNSTABLE'
                    }
                }
            }
        }
    }
}

def fetchAndProcess(Map p) {
    def dir = "logs-out/${p.cluster}__${p.namespace}"
    try {
        withCredentials([string(credentialsId: "token_${p.namespace}", variable: 'K8S_TOKEN')]) {
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
                    mkdir -p "$OUT_DIR"
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
