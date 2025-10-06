#!/usr/bin/env bash
# fw-zone-sync-from-urls.sh
# Sync Firewalld zone sources with IPs resolved from given URLs.
# Logs structured JSON to /var/log/fw-zone-sync.jsonl
# Version: 1.2
# Author: ChatGPT (GPT-5)

set -euo pipefail

LOGFILE="/var/log/fw-zone-sync.jsonl"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
ZONE=""
DRY_RUN=0

# ensure log file exists and writable
touch "$LOGFILE" 2>/dev/null || {
  echo "ERROR: cannot write to $LOGFILE (need root?)" >&2
  exit 1
}

json_log() {
  # args: level, msg, [extra_fields_json]
  local level="$1"
  local msg="$2"
  local extra="${3:-{}}"
  local ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq -cn --arg ts "$ts" --arg lvl "$level" --arg msg "$msg" --arg zone "$ZONE" \
     --argjson extra "$extra" \
     '{timestamp:$ts,level:$lvl,zone:$zone,message:$msg} + $extra' >> "$LOGFILE"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

print_usage() {
  cat <<EOF
Usage:
  $0 [--dry-run] <zone> URL [URL ...]
  $0 [--dry-run] <zone> -f <file_with_urls>
EOF
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
    json_log "ERROR" "Missing dig/getent tools" '{}'
    return 1
  fi
  printf '%s\n' "${ips[@]}" | sort -u
}

normalize_ip_source() {
  local ip="$1"
  [[ "$ip" == *:* ]] && echo "${ip}/128" || echo "${ip}/32"
}

# --- parse args ---
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print_usage; exit 0
fi
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1; shift
fi
if [ $# -lt 2 ]; then print_usage; exit 2; fi

ZONE="$1"; shift
URLS=()
if [[ "$1" == "-f" ]]; then
  [ $# -ge 2 ] || { json_log "ERROR" "-f requires a filename" '{}'; exit 2; }
  file="$2"
  [ -f "$file" ] || { json_log "ERROR" "file not found: $file" '{"file":"'"$file"'"}'; exit 2; }
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] && URLS+=("$line")
  done < "$file"
else
  URLS=("$@")
fi

json_log "INFO" "Starting sync for zone" '{"urls_count":'"${#URLS[@]}"'}'

if ! firewall-cmd --get-zones | tr ' ' '\n' | grep -qx "$ZONE"; then
  json_log "ERROR" "Zone not found" '{"zone":"'"$ZONE"'"}'
  exit 3
fi

declare -A desired_map=()
for rawurl in "${URLS[@]}"; do
  host="$rawurl"
  host="${host#*://}"; host="${host%%/*}"; host="${host%%:*}"; host="${host##*@}"
  [ -z "$host" ] && { json_log "WARN" "Unable to parse host" '{"raw":"'"$rawurl"'"}'; continue; }

  mapfile -t ips < <(resolve_ips "$host" || true)
  if [ "${#ips[@]}" -eq 0 ]; then
    json_log "WARN" "No IPs resolved for host" '{"host":"'"$host"'"}'
    continue
  fi

  for ip in "${ips[@]}"; do
    src=$(normalize_ip_source "$ip")
    desired_map["$src"]=1
    json_log "DEBUG" "Resolved host" '{"host":"'"$host"'", "ip":"'"$src"'"}'
  done
done

desired_file=$(mktemp); current_file=$(mktemp)
to_add_file=$(mktemp); to_remove_file=$(mktemp)
trap 'rm -f "$desired_file" "$current_file" "$to_add_file" "$to_remove_file"' EXIT

for k in "${!desired_map[@]}"; do echo "$k"; done | sort > "$desired_file"

current_sources_raw=$(firewall-cmd --zone="$ZONE" --list-sources 2>/dev/null || true)
if [ -z "$current_sources_raw" ]; then > "$current_file"
else
  for s in $current_sources_raw; do
    [[ "$s" == *"/"* ]] && echo "$s" || echo "$(normalize_ip_source "$s")"
  done | sort > "$current_file"
fi

comm -23 "$desired_file" "$current_file" > "$to_add_file"
comm -13 "$desired_file" "$current_file" > "$to_remove_file"

add_count=$(wc -l < "$to_add_file" | tr -d ' ')
remove_count=$(wc -l < "$to_remove_file" | tr -d ' ')

if [ "$add_count" -eq 0 ] && [ "$remove_count" -eq 0 ]; then
  json_log "INFO" "No changes detected" '{}'
  exit 0
fi

json_log "INFO" "Detected changes" '{"add_count":'"$add_count"',"remove_count":'"$remove_count"'}'

if [ "$DRY_RUN" -eq 1 ]; then
  json_log "INFO" "Dry-run mode: no changes applied" '{}'
  exit 0
fi

PERM_CHANGED=0
while IFS= read -r src; do
  [ -z "$src" ] && continue
  json_log "INFO" "Adding source" '{"source":"'"$src"'"}'
  firewall-cmd --zone="$ZONE" --add-source="$src" >/dev/null 2>&1 || json_log "WARN" "Runtime add failed" '{"source":"'"$src"'"}'
  firewall-cmd --permanent --zone="$ZONE" --add-source="$src" >/dev/null 2>&1 && PERM_CHANGED=1 || json_log "WARN" "Permanent add failed" '{"source":"'"$src"'"}'
done < "$to_add_file"

while IFS= read -r src; do
  [ -z "$src" ] && continue
  json_log "INFO" "Removing source" '{"source":"'"$src"'"}'
  firewall-cmd --zone="$ZONE" --remove-source="$src" >/dev/null 2>&1 || json_log "WARN" "Runtime remove failed" '{"source":"'"$src"'"}'
  firewall-cmd --permanent --zone="$ZONE" --remove-source="$src" >/dev/null 2>&1 && PERM_CHANGED=1 || json_log "WARN" "Permanent remove failed" '{"source":"'"$src"'"}'
done < "$to_remove_file"

if [ "$PERM_CHANGED" -eq 1 ]; then
  firewall-cmd --reload >/dev/null 2>&1
  json_log "INFO" "Firewalld reloaded" '{}'
fi

json_log "INFO" "Sync completed" '{"zone":"'"$ZONE"'"}'
exit 0
