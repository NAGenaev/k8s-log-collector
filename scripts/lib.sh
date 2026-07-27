#!/usr/bin/env bash
# Fetch, count and colorize kubectl logs for one (cluster, namespace) pair.
# Expects env vars: API_SERVER, INSECURE, CLUSTER, NAMESPACE, DEPLOY, SINCE,
# TAIL_LINES, INCLUDE_PREVIOUS, LOG_LEVELS, OUT_DIR, K8S_TOKEN.
# LOG_LEVELS: "WARN_ERROR" (default, only WARN/ERROR lines in the log output)
#             or "ALL" (also pass through INFO/other lines).

ERROR_PATTERN="${ERROR_PATTERN:-ERROR}"
WARN_PATTERN="${WARN_PATTERN:-WARN}"

GREEN_BG=$(printf '\033[1;30;42m')
RED_TXT=$(printf '\033[1;31m')
YEL_TXT=$(printf '\033[1;33m')
RST=$(printf '\033[0m')

# Wraps a name (cluster/namespace, pod/container, ...) in a bright-green fill.
name() {
  printf '%s%s%s' "$GREEN_BG" "$1" "$RST"
}

# Renders "ERROR=n WARN=m" from a *.stats file with ERROR in red, WARN in yellow.
fmt_counts() {
  local statsfile="$1" err warn
  err=$(grep '^ERROR=' "$statsfile" | cut -d= -f2)
  warn=$(grep '^WARN=' "$statsfile" | cut -d= -f2)
  printf '%sERROR=%s%s %sWARN=%s%s' "$RED_TXT" "${err:-0}" "$RST" "$YEL_TXT" "${warn:-0}" "$RST"
}

# Prefixes every status line with [cluster/namespace] (bright-green fill) so
# parallel branches stay distinguishable in the interleaved Jenkins console.
tag() {
  echo "$(name "[$CLUSTER/$NAMESPACE]") $*"
}

# $5 (ca_cert_b64) is optional: base64-encoded PEM of the cluster's CA
# certificate (public data, not a secret — safe to keep in config/clusters.yaml).
# When set, it takes precedence over $3 (insecure) for TLS verification.
k8s_setup() {
  local server="$1" token="$2" insecure="$3" kubeconfig="$4" ca_cert_b64="${5:-}"
  local tls_flag
  mkdir -p "$(dirname "$kubeconfig")"
  if [ -n "$ca_cert_b64" ]; then
    local ca_file; ca_file="$(dirname "$kubeconfig")/ca.crt"
    printf '%s' "$ca_cert_b64" | base64 -d > "$ca_file"
    tls_flag="--certificate-authority=$ca_file"
  elif [ "$insecure" = "true" ]; then
    tls_flag="--insecure-skip-tls-verify=true"
  else
    tls_flag=""
  fi
  kubectl --kubeconfig="$kubeconfig" config set-cluster the-cluster --server="$server" $tls_flag >/dev/null
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
  printf '%s\n' "$json" | jq -r '
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

# Reads $raw, writes a colorized copy to $color (ERROR = white-on-red fill,
# WARN = black-on-yellow fill) and a small "ERROR=n\nWARN=n" properties file
# to $stats. Substring match, not regex. INFO/other lines are passed through
# only when LOG_LEVELS=ALL; ERROR/WARN lines and counts are unaffected by the
# filter either way.
process_log() {
  local raw="$1" color="$2" stats="$3"
  local red_bg yel_bg rst show_other
  red_bg=$(printf '\033[1;97;41m')
  yel_bg=$(printf '\033[1;30;43m')
  rst=$(printf '\033[0m')
  show_other=1
  [ "${LOG_LEVELS:-WARN_ERROR}" = "WARN_ERROR" ] && show_other=0
  awk -v RED="$red_bg" -v YEL="$yel_bg" -v RST="$rst" -v show_other="$show_other" \
      -v ep="$ERROR_PATTERN" -v wp="$WARN_PATTERN" -v statsfile="$stats" '
    BEGIN { err=0; warn=0 }
    index($0, ep) > 0 { err++; printf "%s%s%s\n", RED, $0, RST; next }
    index($0, wp) > 0 { warn++; printf "%s%s%s\n", YEL, $0, RST; next }
    { if (show_other == "1") print }
    END { printf "ERROR=%d\nWARN=%d\n", err, warn > statsfile }
  ' "$raw" > "$color"
}

run_pair() {
  local kubeconfig; kubeconfig="$(mktemp -d)/kubeconfig"
  k8s_setup "$API_SERVER" "$K8S_TOKEN" "$INSECURE" "$kubeconfig" "${CA_CERT_B64:-}"
  export KUBECONFIG="$kubeconfig"

  tag "resolving deployment '$DEPLOY'..."
  local selector
  if ! selector=$(resolve_selector "$NAMESPACE" "$DEPLOY"); then
    tag "SKIP: deployment '$DEPLOY' not found"
    echo "reason=deployment '$DEPLOY' not found in $CLUSTER/$NAMESPACE" > "$OUT_DIR/.skip"; return 0
  fi
  if [ -z "$selector" ]; then
    tag "SKIP: deployment '$DEPLOY' has no matchLabels selector"
    echo "reason=deployment '$DEPLOY' has no matchLabels selector" > "$OUT_DIR/.skip"; return 0
  fi

  local pods; pods=$(list_pods "$NAMESPACE" "$selector")
  if [ -z "$pods" ]; then
    tag "SKIP: no pods found for selector '$selector'"
    echo "reason=no pods found for selector '$selector'" > "$OUT_DIR/.skip"; return 0
  fi
  tag "selector='$selector', $(printf '%s\n' "$pods" | wc -l | tr -d ' ') pod/container(s) found"

  local tab; tab=$(printf '\t')
  printf '%s\n' "$pods" | while IFS="$tab" read -r pod container restarts; do
    [ -z "$pod" ] && continue
    local base="$OUT_DIR/${pod}__${container}"
    kubectl --request-timeout=30s -n "$NAMESPACE" logs "$pod" -c "$container" \
        --since="$SINCE" --tail="$TAIL_LINES" > "${base}.raw.log" 2>"${base}.fetch.err" \
        || echo "(failed to fetch current logs, see ${base}.fetch.err)" >> "${base}.raw.log"
    process_log "${base}.raw.log" "${base}.color.log" "${base}.stats"
    tag "$(name "$pod/$container"): $(fmt_counts "${base}.stats")"

    if [ "$INCLUDE_PREVIOUS" = "true" ] && [ "${restarts:-0}" -gt 0 ]; then
      local pbase="$OUT_DIR/${pod}__${container}__previous"
      if kubectl --request-timeout=30s -n "$NAMESPACE" logs "$pod" -c "$container" \
          --previous --tail="$TAIL_LINES" > "${pbase}.raw.log" 2>"${pbase}.fetch.err"; then
        process_log "${pbase}.raw.log" "${pbase}.color.log" "${pbase}.stats"
        tag "$pod/$container (previous): $(cat "${pbase}.stats" | tr '\n' ' ')"
      else
        rm -f "${pbase}.raw.log" "${pbase}.fetch.err"
      fi
    fi
  done
}
