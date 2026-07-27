#!/usr/bin/env bash
# Fetch, count and colorize kubectl logs for one (cluster, namespace) pair.
# Expects env vars: API_SERVER, INSECURE, CLUSTER, NAMESPACE, DEPLOY, SINCE,
# TAIL_LINES, INCLUDE_PREVIOUS, OUT_DIR, K8S_TOKEN.

ERROR_PATTERN="${ERROR_PATTERN:-ERROR}"
WARN_PATTERN="${WARN_PATTERN:-WARN}"

k8s_setup() {
  local server="$1" token="$2" insecure="$3" kubeconfig="$4"
  mkdir -p "$(dirname "$kubeconfig")"
  kubectl --kubeconfig="$kubeconfig" config set-cluster the-cluster --server="$server" \
      $( [ "$insecure" = "true" ] && echo --insecure-skip-tls-verify=true ) >/dev/null
  kubectl --kubeconfig="$kubeconfig" config set-credentials the-user --token="$token" >/dev/null
  kubectl --kubeconfig="$kubeconfig" config set-context the-context \
      --cluster=the-cluster --user=the-user --namespace="$NAMESPACE" >/dev/null
  kubectl --kubeconfig="$kubeconfig" config use-context the-context >/dev/null
}

# Resolve the pod-selector for a deployment from its spec.selector.matchLabels.
# Returns non-zero if the deployment itself was not found.
resolve_selector() {
  local ns="$1" deploy="$2" json
  json=$(kubectl --request-timeout=15s -n "$ns" get deployment "$deploy" -o json 2>/dev/null) || return 1
  echo "$json" | jq -r '
    (.spec.selector.matchLabels // {}) as $m
    | if ($m|length) > 0 then ($m | to_entries | map("\(.key)=\(.value)") | join(",")) else empty end'
}

# Emits one line per pod+container: "<pod>\t<container>\t<restartCount>"
list_pods() {
  local ns="$1" selector="$2"
  kubectl --request-timeout=15s -n "$ns" get pods -l "$selector" -o json | jq -r '
    .items[] | . as $p | ($p.status.containerStatuses // []) as $cs |
    $p.spec.containers[].name as $cname |
    ( [$cs[] | select(.name==$cname)][0].restartCount // 0 ) as $rc |
    "\($p.metadata.name)\t\($cname)\t\($rc)"'
}

# Reads $raw, writes a colorized copy to $color (ERROR=red, WARN=yellow) and
# a small "ERROR=n\nWARN=n" properties file to $stats. Substring match, not regex.
process_log() {
  local raw="$1" color="$2" stats="$3"
  awk -v RED=$'\033[31m' -v YEL=$'\033[33m' -v RST=$'\033[0m' \
      -v ep="$ERROR_PATTERN" -v wp="$WARN_PATTERN" -v statsfile="$stats" '
    BEGIN { err=0; warn=0 }
    index($0, ep) > 0 { err++; printf "%s%s%s\n", RED, $0, RST; next }
    index($0, wp) > 0 { warn++; printf "%s%s%s\n", YEL, $0, RST; next }
    { print }
    END { printf "ERROR=%d\nWARN=%d\n", err, warn > statsfile }
  ' "$raw" > "$color"
}

run_pair() {
  local kubeconfig; kubeconfig="$(mktemp -d)/kubeconfig"
  k8s_setup "$API_SERVER" "$K8S_TOKEN" "$INSECURE" "$kubeconfig"
  export KUBECONFIG="$kubeconfig"

  local selector
  if ! selector=$(resolve_selector "$NAMESPACE" "$DEPLOY"); then
    echo "reason=deployment '$DEPLOY' not found in $CLUSTER/$NAMESPACE" > "$OUT_DIR/.skip"; return 0
  fi
  if [ -z "$selector" ]; then
    echo "reason=deployment '$DEPLOY' has no matchLabels selector" > "$OUT_DIR/.skip"; return 0
  fi

  local pods; pods=$(list_pods "$NAMESPACE" "$selector")
  if [ -z "$pods" ]; then
    echo "reason=no pods found for selector '$selector'" > "$OUT_DIR/.skip"; return 0
  fi

  while IFS=$'\t' read -r pod container restarts; do
    [ -z "$pod" ] && continue
    local base="$OUT_DIR/${pod}__${container}"
    kubectl --request-timeout=30s -n "$NAMESPACE" logs "$pod" -c "$container" \
        --since="$SINCE" --tail="$TAIL_LINES" > "${base}.raw.log" 2>"${base}.fetch.err" \
        || echo "(failed to fetch current logs, see ${base}.fetch.err)" >> "${base}.raw.log"
    process_log "${base}.raw.log" "${base}.color.log" "${base}.stats"

    if [ "$INCLUDE_PREVIOUS" = "true" ] && [ "${restarts:-0}" -gt 0 ]; then
      local pbase="$OUT_DIR/${pod}__${container}__previous"
      if kubectl --request-timeout=30s -n "$NAMESPACE" logs "$pod" -c "$container" \
          --previous --tail="$TAIL_LINES" > "${pbase}.raw.log" 2>"${pbase}.fetch.err"; then
        process_log "${pbase}.raw.log" "${pbase}.color.log" "${pbase}.stats"
      else
        rm -f "${pbase}.raw.log" "${pbase}.fetch.err"
      fi
    fi
  done <<< "$pods"
}
