#!/usr/bin/env bash
# fw-zone-sync.sh
# Sync Firewalld zone sources from DNS hostnames (supports multiple zones via config file)
# Logs structured JSON (with hostnames) to /var/log/fw-zone-sync.jsonl
# Version: 2.0
# Author: ChatGPT

set -euo pipefail

LOGFILE="/var/log/fw-zone-sync.jsonl"
TMPDIR=$(mktemp -d)

# -----------------------
# Logging function
# -----------------------
ZONE=""
json_log() {
    local level="$1"; shift
    local msg="$1"; shift
    local extra="${1:-}"  # optional extra JSON
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # default extra to empty JSON object
    [[ -z "$extra" ]] && extra="{}"

    # safely append extra JSON
    echo "$extra" | jq -c --arg ts "$ts" --arg lvl "$level" --arg msg "$msg" --arg zone "$ZONE" \
        '{timestamp:$ts,level:$lvl,zone:$zone,message:$msg} + .' >> "$LOGFILE"
}

# -----------------------
# Helpers
# -----------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

normalize_ip_source() {
    local ip="$1"
    [[ "$ip" == *:* ]] && echo "${ip}/128" || echo "${ip}/32"
}

resolve_ips() {
    local host="$1"
    local -a ips=()

    if command_exists dig; then
        mapfile -t a4 < <(dig +short A "$host" | sed '/^$/d')
        mapfile -t a6 < <(dig +short AAAA "$host" | sed '/^$/d')
        ips=("${a4[@]}" "${a6[@]}")
    elif command_exists getent; then
        mapfile -t ips < <(getent ahosts "$host" | awk '{print $1}' | sort -u)
    else
        json_log "ERROR" "Missing dig/getent tools"
        return 1
    fi
    printf '%s\n' "${ips[@]}" | sort -u
}

get_zone_sources() {
    firewall-cmd --zone="$1" --list-sources | tr ' ' '\n' | sort -u
}

# -----------------------
# Update zone sources (with JSON logging)
# -----------------------
update_zone_sources() {
    local zone="$1"
    local desired_file="$2"
    local current_file="$3"
    local -n host_ip_map_ref=$4  # pass HOST_IP_MAP by reference

    ZONE="$zone"
    local added removed
    added=$(comm -23 "$desired_file" "$current_file" || true)
    removed=$(comm -13 "$desired_file" "$current_file" || true)

    mapfile -t added_ips <<< "$added"
    mapfile -t removed_ips <<< "$removed"

    if [[ -z "${added_ips[*]}" && -z "${removed_ips[*]}" ]]; then
        json_log "INFO" "No IP changes detected for zone '$zone'"
        return
    fi

    # Build host->IP JSON array
    if [ "${#host_ip_map_ref[@]}" -gt 0 ]; then
        host_ip_json=$(printf '%s\n' "${host_ip_map_ref[@]}" | jq -s .)
    else
        host_ip_json="[]"
    fi

    # Dry-run: log IPs that would be added/removed
    if [ "$DRY_RUN" -eq 1 ]; then
        added_json=$(printf '%s\n' "${added_ips[@]}" | jq -R . | jq -s .)
        removed_json=$(printf '%s\n' "${removed_ips[@]}" | jq -R . | jq -s .)
        json_log "INFO" "Dry-run: IPs that would be added/removed" \
            "{\"added_ips\":$added_json,\"removed_ips\":$removed_json,\"host_ips\":$host_ip_json}"
        return
    fi

    # Apply added IPs
    if [ "${#added_ips[@]}" -gt 0 ]; then
        added_json=$(printf '%s\n' "${added_ips[@]}" | jq -R . | jq -s .)
        for ip in "${added_ips[@]}"; do
            [[ -z "$ip" ]] && continue
            firewall-cmd --zone="$zone" --add-source="$ip" --permanent
        done
        json_log "INFO" "Added IPs to zone" "{\"added_ips\":$added_json,\"host_ips\":$host_ip_json}"
    fi

    # Apply removed IPs
    if [ "${#removed_ips[@]}" -gt 0 ]; then
        removed_json=$(printf '%s\n' "${removed_ips[@]}" | jq -R . | jq -s .)
        for ip in "${removed_ips[@]}"; do
            [[ -z "$ip" ]] && continue
            firewall-cmd --zone="$zone" --remove-source="$ip" --permanent
        done
        json_log "INFO" "Removed IPs from zone" "{\"removed_ips\":$removed_json,\"host_ips\":$host_ip_json}"
    fi

    firewall-cmd --reload
    json_log "INFO" "Reloaded zone after updates"
}

# -----------------------
# Process a single zone
# -----------------------
process_zone() {
    local zone="$1"
    shift
    local urls=("$@")
    local desired_file="$TMPDIR/${zone}_desired.txt"
    local current_file="$TMPDIR/${zone}_current.txt"
    declare -a HOST_IP_MAP=()
    ZONE="$zone"
    : > "$desired_file"

    for rawurl in "${urls[@]}"; do
        host="$rawurl"
        host="${host#*://}"; host="${host%%/*}"; host="${host%%:*}"; host="${host##*@}"
        [ -z "$host" ] && { json_log "WARN" "Could not parse host" '{"raw":"'"$rawurl"'"}'; continue; }

        mapfile -t ips < <(resolve_ips "$host" || true)
        if [ "${#ips[@]}" -eq 0 ]; then
            json_log "WARN" "No IPs resolved for host" '{"host":"'"$host"'"}'
            continue
        fi

        for ip in "${ips[@]}"; do
            ip=$(normalize_ip_source "$ip")
            echo "$ip" >> "$desired_file"
            HOST_IP_MAP+=("{\"host\":\"$host\",\"ip\":\"$ip\"}")
        done
    done

    sort -u -o "$desired_file" "$desired_file"
    get_zone_sources "$zone" > "$current_file"

    update_zone_sources "$zone" "$desired_file" "$current_file" HOST_IP_MAP
}

# -----------------------
# CLI argument parsing
# -----------------------
DRY_RUN=0
CONFIG_FILE=""

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

print_usage() {
    cat <<EOF
Usage:
  $0 [--dry-run] ZONE URL [URL ...]
  $0 [--dry-run] -f CONFIG_FILE

CONFIG_FILE format (INI-like):
[zone1]
url1
url2
EOF
}

if [ $# -lt 1 ]; then print_usage; exit 2; fi

if [[ "$1" == "-f" ]]; then
    [ $# -ge 2 ] || { echo "Missing config file"; exit 2; }
    CONFIG_FILE="$2"
    [ -f "$CONFIG_FILE" ] || { echo "Config file not found: $CONFIG_FILE"; exit 2; }
else
    ZONE="$1"
    shift
    URLS=("$@")
fi

# -----------------------
# Main execution
# -----------------------
if [ -n "$CONFIG_FILE" ]; then
    CURRENT_ZONE=""
    declare -a URLS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove comments and trim
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            if [ -n "$CURRENT_ZONE" ]; then
                process_zone "$CURRENT_ZONE" "${URLS[@]}"
            fi
            CURRENT_ZONE="${BASH_REMATCH[1]}"
            URLS=()
        else
            URLS+=("$line")
        fi
    done < "$CONFIG_FILE"
    if [ -n "$CURRENT_ZONE" ]; then
        process_zone "$CURRENT_ZONE" "${URLS[@]}"
    fi
else
    process_zone "$ZONE" "${URLS[@]}"
fi

rm -rf "$TMPDIR"
json_log "INFO" "All zones processed"
exit 0
