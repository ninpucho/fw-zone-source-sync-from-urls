#!/usr/bin/env bash
# fw-zone-sync.sh
# Sync Firewalld zone sources from DNS hostnames (supports multiple zones via config file)
# Logs structured JSON to /var/log/fw-zone-sync.jsonl
# Version: 1.3
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
    local extra="${1:-{}}"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    jq -cn --arg ts "$ts" --arg lvl "$level" --arg msg "$msg" --arg zone "$ZONE" \
        --argjson extra "$extra" \
        '{timestamp:$ts,level:$lvl,zone:$zone,message:$msg} + $extra' >> "$LOGFILE"
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

update_zone_sources() {
    local zone="$1"
    local desired_file="$2"
    local current_file="$3"

    ZONE="$zone"
    local added removed
    added=$(comm -23 "$desired_file" "$current_file" || true)
    removed=$(comm -13 "$desired_file" "$current_file" || true)

    if [[ -z "$added" && -z "$removed" ]]; then
        json_log "INFO" "No IP changes detected for zone '$zone'"
        return
    fi

    mapfile -t added_ips <<< "$added"
    mapfile -t removed_ips <<< "$removed"

    if [ "$DRY_RUN" -eq 1 ]; then
        json_log "INFO" "Dry-run: IPs that would be added/removed" \
            '{"added_ips":'"$(jq -nc --argjson a "$(printf '%s\n' "${added_ips[@]}" | jq -R . | jq -s .)" '$a')"',"removed_ips":'"$(jq -nc --argjson r "$(printf '%s\n' "${removed_ips[@]}" | jq -R . | jq -s .)" '$r')"'}'
        return
    fi

    # Apply added IPs
    for ip in "${added_ips[@]}"; do
        [[ -z "$ip" ]] && continue
        firewall-cmd --zone="$zone" --add-source="$ip" --permanent
    done
    if [[ "${#added_ips[@]}" -gt 0 ]]; then
        json_log "INFO" "Added IPs to zone" \
            '{"added_ips":'"$(jq -nc --argjson a "$(printf '%s\n' "${added_ips[@]}" | jq -R . | jq -s .)" '$a')"'}'
    fi

    # Apply removed IPs
    for ip in "${removed_ips[@]}"; do
        [[ -z "$ip" ]] && continue
        firewall-cmd --zone="$zone" --remove-source="$ip" --permanent
    done
    if [[ "${#removed_ips[@]}" -gt 0 ]]; then
        json_log "INFO" "Removed IPs from zone" \
            '{"removed_ips":'"$(jq -nc --argjson r "$(printf '%s\n' "${removed_ips[@]}" | jq -R . | jq -s .)" '$r')"'}'
    fi

    firewall-cmd --reload
    json_log "INFO" "Reloaded zone after updates"
}


# -----------------------
# Parse arguments
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

[zone2]
url3
url4
EOF
}

if [ $# -lt 1 ]; then print_usage; exit 2; fi

if [[ "$1" == "-f" ]]; then
    [ $# -ge 2 ] || { echo "Missing config file"; exit 2; }
    CONFIG_FILE="$2"
    [ -f "$CONFIG_FILE" ] || { echo "Config file not found: $CONFIG_FILE"; exit 2; }
else
    # Single zone mode
    ZONE="$1"
    shift
    URLS=("$@")
fi

# -----------------------
# Function to process a single zone
# -----------------------
process_zone() {
    local zone="$1"
    shift
    local urls=("$@")
    local desired_file="$TMPDIR/${zone}_desired.txt"
    local current_file="$TMPDIR/${zone}_current.txt"

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
            echo "$(normalize_ip_source "$ip")" >> "$desired_file"
        done
    done

    sort -u -o "$desired_file" "$desired_file"
    get_zone_sources "$zone" > "$current_file"

    if [ "$DRY_RUN" -eq 1 ]; then
        json_log "INFO" "Dry-run mode: would update zone" '{"zone":"'"$zone"'"}'
        return
    fi

    update_zone_sources "$zone" "$desired_file" "$current_file"
}

# -----------------------
# Main execution
# -----------------------
if [ -n "$CONFIG_FILE" ]; then
    # Multi-zone mode: parse INI-like config
    CURRENT_ZONE=""
    declare -a URLS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                     # Remove comments
        line="${line#"${line%%[![:space:]]*}"}" # Trim leading
        line="${line%"${line##*[![:space:]]}"}" # Trim trailing
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            # process previous zone
            if [ -n "$CURRENT_ZONE" ]; then
                process_zone "$CURRENT_ZONE" "${URLS[@]}"
            fi
            CURRENT_ZONE="${BASH_REMATCH[1]}"
            URLS=()
        else
            URLS+=("$line")
        fi
    done < "$CONFIG_FILE"
    # last zone
    if [ -n "$CURRENT_ZONE" ]; then
        process_zone "$CURRENT_ZONE" "${URLS[@]}"
    fi
else
    # Single zone mode
    process_zone "$ZONE" "${URLS[@]}"
fi

rm -rf "$TMPDIR"
json_log "INFO" "All zones processed"
exit 0
