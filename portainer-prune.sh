#!/bin/sh
# =============================================================================
# portainer-prune.sh
#
# Prunes dangling (or all unused) Docker images on a schedule via the
# Portainer API.  Runs as a system cron job directly on each host.
#
# Each host reads portainer-prune.conf, finds its own Portainer endpoint ID
# by hostname, and calls:
#   POST /api/endpoints/{id}/docker/images/prune
#
# Requires only tools present on any standard Linux host:
# sh · wget · mkdir · date · hostname · grep · sed · awk
#
# Usage:
#   Called automatically by system cron.
#   Can also be run manually for testing:
#
#     sh /opt/portainer-prune/portainer-prune.sh
#     DRY_RUN=true sh /opt/portainer-prune/portainer-prune.sh
# =============================================================================

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/portainer-prune.conf"
HOST_NAME="$(hostname)"
SCRIPT_PID="$$"

# =============================================================================
# LOAD CONFIG
# Strips CRLF line endings before sourcing -- handles config files edited on
# Windows or written via NFS mounts that perform CR/LF translation.
# =============================================================================
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
        echo "       Copy portainer-prune.conf.example to portainer-prune.conf and edit it." >&2
        exit 1
    fi

    _cfg_tmp="$(mktemp)"
    tr -d '\r' < "$CONFIG_FILE" > "$_cfg_tmp"
    . "$_cfg_tmp"
    rm -f "$_cfg_tmp"

    LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/logs/portainer-prune.log}"
    MAX_LOG_SIZE_KB="${MAX_LOG_SIZE_KB:-10240}"
    MAX_LOG_ARCHIVES="${MAX_LOG_ARCHIVES:-5}"
    RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
    RETRY_DELAY="${RETRY_DELAY:-5}"
    PORTAINER_TLS_VERIFY="${PORTAINER_TLS_VERIFY:-true}"
    PORTAINER_BASE_URL="${PORTAINER_BASE_URL:-}"
    PORTAINER_API_KEY="${PORTAINER_API_KEY:-}"
    PRUNE_ENABLED="${PRUNE_ENABLED:-true}"
    PRUNE_ALL_IMAGES="${PRUNE_ALL_IMAGES:-false}"
    DISCORD_ENABLED="${DISCORD_ENABLED:-false}"
    DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
    DISCORD_USERNAME="${DISCORD_USERNAME:-Portainer}"

    _env_dry_run="$(echo "${DRY_RUN:-}" | tr '[:upper:]' '[:lower:]')"
    _cfg_dry_run="$(echo "${DRY_RUN_CONFIG:-false}" | tr '[:upper:]' '[:lower:]')"
    if [ "$_env_dry_run" = "true" ] || [ "$_env_dry_run" = "1" ]; then
        DRY_RUN=true
    elif [ "$_env_dry_run" = "false" ] || [ "$_env_dry_run" = "0" ]; then
        DRY_RUN=false
    else
        DRY_RUN="$_cfg_dry_run"
    fi
}

# =============================================================================
# LOGGING
# mkdir-based lock -- atomic on any POSIX filesystem including NFS.
# Console output goes to stderr so it never pollutes command substitutions.
# =============================================================================
setup_logging() {
    LOG_DIR="$(dirname "$LOG_FILE")"
    mkdir -p "$LOG_DIR"
    LOG_LOCK_DIR="${LOG_FILE}.lock.d"
}

_acquire_log_lock() {
    local retries=30
    while [ $retries -gt 0 ]; do
        if mkdir "$LOG_LOCK_DIR" 2>/dev/null; then
            return 0
        fi
        retries=$((retries - 1))
        sleep 0.1 2>/dev/null || sleep 1
    done
    return 0
}

_release_log_lock() {
    rmdir "$LOG_LOCK_DIR" 2>/dev/null || true
}

log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${timestamp}] [${level}] [host:${HOST_NAME}] [pid:${SCRIPT_PID}] ${message}"
    _acquire_log_lock
    echo "$line" >> "$LOG_FILE"
    _release_log_lock
    echo "$line" >&2
}

# =============================================================================
# LOG ROTATION
# =============================================================================
rotate_log_if_needed() {
    [ -f "$LOG_FILE" ] || return 0
    local size_kb
    size_kb="$(du -k "$LOG_FILE" 2>/dev/null | awk '{print $1}')"
    [ "${size_kb:-0}" -lt "$MAX_LOG_SIZE_KB" ] && return 0

    local archive="${LOG_FILE}.$(date '+%Y%m%d-%H%M%S').${HOST_NAME}"
    _acquire_log_lock
    if [ -f "$LOG_FILE" ]; then
        mv "$LOG_FILE" "$archive"
        ( gzip "$archive" 2>/dev/null || true ) &
    fi
    _release_log_lock
    log "INFO" "Log rotated -> ${archive}.gz"

    ls -t "${LOG_DIR}/$(basename "$LOG_FILE").*.gz" 2>/dev/null \
        | tail -n "+$((MAX_LOG_ARCHIVES + 1))" \
        | while read -r old; do rm -f "$old"; done
}

# =============================================================================
# ENDPOINT ID LOOKUP
#
# Reads PORTAINER_ENDPOINT__<hostname> from the sourced config.
# Non-alphanumeric characters in the hostname are replaced with _ so the
# variable name is always valid shell syntax.
#
# Example: hostname "nas-01" -> looks up PORTAINER_ENDPOINT__nas_01
# =============================================================================
find_endpoint_id() {
    local host_key
    host_key="$(echo "$HOST_NAME" | sed 's|[^a-zA-Z0-9_]|_|g')"
    eval "echo \"\${PORTAINER_ENDPOINT__${host_key}:-}\"" 2>/dev/null || true
}

# =============================================================================
# PORTAINER IMAGE PRUNE WITH RETRY
#
# Calls POST /api/endpoints/{id}/docker/images/prune via the Portainer API.
# Portainer returns HTTP 200 with a JSON body:
#   { "ImagesDeleted": [...], "SpaceReclaimed": <bytes> }
#
# Prints the space reclaimed in MB to stdout (for capture by main).
# All log output goes to stderr.
#
# PRUNE_ALL_IMAGES=false (default) -> dangling images only (no query params)
# PRUNE_ALL_IMAGES=true            -> all unused images
# =============================================================================
trigger_prune() {
    local endpoint_id="$1"
    local wget_tls_flag=""
    [ "$PORTAINER_TLS_VERIFY" = "false" ] && wget_tls_flag="--no-check-certificate"

    local prune_url
    if [ "$PRUNE_ALL_IMAGES" = "true" ]; then
        # filters={"dangling":["false"]} selects all unused images
        prune_url="${PORTAINER_BASE_URL}/api/endpoints/${endpoint_id}/docker/images/prune?filters=%7B%22dangling%22%3A%5B%22false%22%5D%7D"
    else
        # No filters -- Docker API default is dangling images only
        prune_url="${PORTAINER_BASE_URL}/api/endpoints/${endpoint_id}/docker/images/prune"
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log "INFO" "[DRY RUN] Would POST to: ${prune_url}"
        log "INFO" "[DRY RUN] No actual request sent."
        echo "0"
        return 0
    fi

    local attempt=1
    while [ $attempt -le "$RETRY_ATTEMPTS" ]; do
        log "INFO" "Prune attempt ${attempt}/${RETRY_ATTEMPTS} (endpoint ${endpoint_id})"

        local response wget_rc
        wget_rc=0
        response="$(wget -S -O - \
            --post-data="" \
            --header="X-API-Key: ${PORTAINER_API_KEY}" \
            --header="Content-Type: application/json" \
            --timeout=30 \
            $wget_tls_flag \
            "$prune_url" 2>&1)" || wget_rc=$?

        local success=false
        # Check for 2xx in captured headers (when wget supports -S)
        if echo "$response" | grep -qE 'HTTP/[0-9.]+ 2[0-9][0-9]'; then
            success=true
        # Fallback: exit code 0 means the request succeeded
        elif [ "$wget_rc" -eq 0 ]; then
            success=true
        fi

        if [ "$success" = "true" ]; then
            local space_bytes space_mb
            space_bytes="$(echo "$response" | grep -o '"SpaceReclaimed":[0-9]*' | awk -F: '{print $2}')"
            space_mb="$(echo "${space_bytes:-0}" | awk '{printf "%.1f", $1/1024/1024}')"
            log "INFO" "Prune successful -- space reclaimed: ${space_mb} MB"
            echo "$space_mb"
            return 0
        else
            local err
            err="$(echo "$response" | grep -oE 'HTTP/[0-9.]+ [0-9]+[^\r]*' | head -1 | tr -d '\r')"
            log "WARN" "Prune failed on attempt ${attempt}${err:+ (${err})}"
        fi

        attempt=$((attempt + 1))
        if [ $attempt -le "$RETRY_ATTEMPTS" ]; then
            log "INFO" "Waiting ${RETRY_DELAY}s before retry..."
            sleep "$RETRY_DELAY"
        fi
    done

    return 1
}

# =============================================================================
# DISCORD NOTIFICATION
# =============================================================================

# Escape backslashes and double-quotes for embedding in JSON strings.
# Uses printf to avoid echo interpreting values that start with '-'.
_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

discord_notify() {
    local title="$1"
    local description="$2"
    local color="$3"   # 3066993=green, 15158332=red

    [ "$DISCORD_ENABLED" = "true" ] || return 0

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        log "WARN" "Discord enabled but DISCORD_WEBHOOK_URL is not set -- skipping."
        return 0
    fi

    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local prune_scope
    prune_scope="$([ "$PRUNE_ALL_IMAGES" = "true" ] && echo "All unused" || echo "Dangling only")"

    local json
    json="{
  \"username\": \"$(_esc "$DISCORD_USERNAME")\",
  \"embeds\": [{
    \"title\": \"$(_esc "$title")\",
    \"description\": \"$(_esc "$description")\",
    \"color\": ${color},
    \"fields\": [
      { \"name\": \"Host\",  \"value\": \"$(_esc "$HOST_NAME")\",    \"inline\": true },
      { \"name\": \"Scope\", \"value\": \"$(_esc "$prune_scope")\", \"inline\": true }
    ],
    \"footer\": { \"text\": \"Portainer Image Prune\" },
    \"timestamp\": \"${timestamp}\"
  }]
}"

    local discord_response
    discord_response="$(wget -S -O /dev/null \
        --post-data="$json" \
        --header="Content-Type: application/json" \
        --timeout=30 \
        "$DISCORD_WEBHOOK_URL" 2>&1 || true)"
    if echo "$discord_response" | grep -qE 'HTTP/[0-9.]+ 2[0-9][0-9]'; then
        log "INFO" "Discord notification sent"
    else
        log "WARN" "Failed to send Discord notification (non-critical)"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    load_config
    setup_logging

    # Per-host execution lock so overlapping cron runs don't collide.
    local exec_lock_dir="/tmp/portainer-prune-${HOST_NAME}.lock.d"
    local _lock_owned=false
    if mkdir "$exec_lock_dir" 2>/dev/null; then
        _lock_owned=true
    else
        log "INFO" "Another instance running on ${HOST_NAME}, waiting..."
        local wait=0
        while [ -d "$exec_lock_dir" ] && [ $wait -lt 60 ]; do
            sleep 1
            wait=$((wait + 1))
        done
        if mkdir "$exec_lock_dir" 2>/dev/null; then
            _lock_owned=true
        fi
    fi
    if [ "$_lock_owned" = "true" ]; then
        trap 'rmdir "$exec_lock_dir" 2>/dev/null || true' EXIT
    fi

    rotate_log_if_needed

    local prune_scope
    prune_scope="$([ "$PRUNE_ALL_IMAGES" = "true" ] && echo "all unused" || echo "dangling only")"

    log "INFO" "===================================================="
    log "INFO" "Portainer image prune starting"
    log "INFO" "  Host    : ${HOST_NAME}"
    log "INFO" "  Scope   : ${prune_scope}"
    log "INFO" "  DRY RUN : ${DRY_RUN}"
    log "INFO" "===================================================="

    if [ "$PRUNE_ENABLED" != "true" ]; then
        log "INFO" "PRUNE_ENABLED is not 'true' -- skipping."
        exit 0
    fi

    if [ -z "$PORTAINER_BASE_URL" ]; then
        log "ERROR" "PORTAINER_BASE_URL is not set in portainer-prune.conf"
        exit 1
    fi

    if [ -z "$PORTAINER_API_KEY" ]; then
        log "ERROR" "PORTAINER_API_KEY is not set in portainer-prune.conf"
        exit 1
    fi

    local endpoint_id
    endpoint_id="$(find_endpoint_id)"

    if [ -z "$endpoint_id" ]; then
        local safe_host
        safe_host="$(echo "$HOST_NAME" | sed 's|[^a-zA-Z0-9_]|_|g')"
        log "WARN" "No Portainer endpoint ID configured for host: ${HOST_NAME}"
        log "WARN" "Add PORTAINER_ENDPOINT__${safe_host}=<id> to portainer-prune.conf"
        log "WARN" "Find IDs: Portainer -> Environments -> click env -> note the ID in the URL"
        exit 0
    fi

    log "INFO" "Using Portainer endpoint ID: ${endpoint_id}"

    local space_mb
    if space_mb="$(trigger_prune "$endpoint_id")"; then
        log "INFO" "Image prune complete (${space_mb} MB reclaimed on ${HOST_NAME})"
        discord_notify \
            "Image prune complete" \
            "Pruned **${prune_scope}** images on **${HOST_NAME}**. Space reclaimed: **${space_mb} MB**." \
            "3066993"
    else
        log "ERROR" "Image prune failed on ${HOST_NAME} after ${RETRY_ATTEMPTS} attempt(s)"
        discord_notify \
            "Image prune failed" \
            "Failed to prune images on **${HOST_NAME}** after ${RETRY_ATTEMPTS} attempt(s). Check the log for details." \
            "15158332"
        exit 1
    fi
}

main "$@"
