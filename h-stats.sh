#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/h-manifest.conf"

LOG_FILE="${CUSTOM_LOG_BASENAME}.log"
VERSION_VALUE="${CUSTOM_VERSION:-}"
ALGO_VALUE="${CUSTOM_ALGO:-}"
BIN_PATH="$SCRIPT_DIR/golden-miner-pool-prover"
IGNORE_PCI_BUS_00=${IGNORE_PCI_BUS_00:-1}

DEVICES_VALUE=""
EXTRA_ARGS_VALUE=""
if [[ -f "${CUSTOM_CONFIG_FILENAME:-}" ]]; then
  # shellcheck source=/dev/null
  source "$CUSTOM_CONFIG_FILENAME"
  DEVICES_VALUE="${DEVICES:-}"
  EXTRA_ARGS_VALUE="${EXTRA_ARGS:-}"
fi

json_escape() {
  local str=${1-}
  str=${str//\/\\}
  str=${str//"/\\"}
  str=${str//$'\n'/\\n}
  str=${str//$'\r'/\\r}
  str=${str//$'\t'/\\t}
  echo "$str"
}

array_to_json_numbers() {
  local -n arr_ref=$1
  local default=${2:-0}
  local output="["
  local val
  for val in "${arr_ref[@]}"; do
    [[ -z $val ]] && val=$default
    output+="${val},"
  done
  if [[ $output == "[" ]]; then
    printf '[]'
  else
    printf '%s' "${output%,}]"
  fi
}

declare -A selected_idx
declare -a selected_order
selected_any=false

add_selected_devices() {
  local list="$1"
  list=${list//[[:space:]]/}
  [[ -z $list ]] && return

  IFS=',' read -ra tokens <<< "$list"
  local token added=false
  for token in "${tokens[@]}"; do
    [[ -z $token ]] && continue
    if [[ $token =~ ^[0-9]+$ ]]; then
      int_idx=$((10#$token))
      if [[ -z ${selected_idx[$int_idx]:-} ]]; then
        selected_idx[$int_idx]=1
        selected_order+=($int_idx)
      fi
      added=true
    else
      echo "WARNING: ignoring invalid device token '$token'" >&2
    fi
  done

  if $added; then
    selected_any=true
  fi
}

should_skip_bus_id() {
  local id=${1,,}
  if [[ $id =~ ^([0-9a-f]{4}|[0-9a-f]{8}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-7])$ ]]; then
    local bus=${BASH_REMATCH[2]}
    local func=${BASH_REMATCH[4]}
    if [[ $bus == "00" ]] && [[ $func == "0" ]]; then
      return 0
    fi
  elif [[ $id =~ ^([0-9a-f]{2}):([0-9a-f]{1,2})\.([0-7])$ ]]; then
    local bus=${BASH_REMATCH[1]}
    local func=${BASH_REMATCH[3]}
    if [[ $bus == "00" ]] && [[ $func == "0" ]]; then
      return 0
    fi
  fi
  return 1
}

get_proc_uptime() {
  if [[ ! -x $BIN_PATH ]]; then
    return 1
  fi
  if ! command -v pgrep >/dev/null 2>&1; then
    return 1
  fi

  mapfile -t pids < <(pgrep -f "$BIN_PATH" 2>/dev/null || true)
  for pid in "${pids[@]}"; do
    [[ -z $pid ]] && continue
    etimes=$(ps -p "$pid" -o etimes= 2>/dev/null | awk 'NR==1 { gsub(/^[ \t]+/, ""); print }')
    if [[ $etimes =~ ^[0-9]+$ ]]; then
      echo "$etimes"
      return 0
    fi
  done

  return 1
}

if [[ -n $DEVICES_VALUE ]]; then
  add_selected_devices "$DEVICES_VALUE"
fi

if ! $selected_any && [[ -n $EXTRA_ARGS_VALUE ]]; then
  eval "set -- $EXTRA_ARGS_VALUE"
  while (($#)); do
    token=$1
    shift
    case $token in
      -d)
        if (($# == 0)); then
          echo "WARNING: -d requires a value" >&2
        else
          add_selected_devices "$1"
          shift
        fi
        ;;
      -d*)
        value=${token#-d}
        if [[ -n $value ]]; then
          add_selected_devices "$value"
        else
          echo "WARNING: -d requires a value" >&2
        fi
        ;;
      --devices)
        if (($# == 0)); then
          echo "WARNING: --devices requires a value" >&2
        else
          add_selected_devices "$1"
          shift
        fi
        ;;
      --devices=*)
        value=${token#*=}
        add_selected_devices "$value"
        ;;
    esac
  done
fi

declare -a temp_arr fan_arr busids_hex bus_arr
temp_arr=()
fan_arr=()
busids_hex=()
bus_arr=()
declare -A skip_idx

if command -v nvidia-smi >/dev/null 2>&1; then
  while IFS=, read -r idx temp fan busid; do
    idx=${idx//[[:space:]]/}
    [[ -z $idx ]] && continue

    temp=${temp//[[:space:]]/}
    if [[ ! $temp =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
      temp=0
    fi
    temp=${temp%%.*}

    fan=${fan//[[:space:]]/}
    if [[ ! $fan =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
      fan=0
    fi
    fan=${fan%%.*}

    busid=${busid//[[:space:]]/}
    [[ -z $busid ]] && busid="0000:00:00.0"

    temp_arr[idx]=$temp
    fan_arr[idx]=$fan
    busids_hex[idx]=${busid,,}
  done < <(nvidia-smi --query-gpu=index,temperature.gpu,fan.speed,pci.bus_id --format=csv,noheader,nounits 2>/dev/null || true)
fi

all_bus_zero=true
for idx in "${!busids_hex[@]}"; do
  id=${busids_hex[$idx]}
  if (( IGNORE_PCI_BUS_00 != 0 )) && should_skip_bus_id "$id"; then
    skip_idx[$idx]=1
  fi
  bus_part=${id%%:*}
  if [[ $id =~ ^([0-9a-fA-F]{4}|[0-9a-fA-F]{8}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.[0-7]$ ]]; then
    bus_part=${BASH_REMATCH[2]}
  elif [[ $id =~ ^([0-9a-fA-F]{2}):([0-9a-fA-F]{1,2})\.[0-7]$ ]]; then
    bus_part=${BASH_REMATCH[1]}
  fi
  if [[ $bus_part =~ ^[0-9a-fA-F]+$ ]]; then
    bus_arr[$idx]=$((16#$bus_part))
    if (( bus_arr[$idx] != 0 )); then
      all_bus_zero=false
    fi
  else
    bus_arr[$idx]=0
  fi
done

if $all_bus_zero; then
  skip_idx=()
fi

declare -A speed_map
if [[ -f $LOG_FILE ]]; then
  while IFS= read -r line; do
    if [[ $line =~ Card-([0-9]+)[[:space:]]+speed:[[:space:]]+([0-9.]+)[[:space:]]+p/s ]]; then
      idx=${BASH_REMATCH[1]}
      rate=${BASH_REMATCH[2]}
      if [[ -z ${speed_map[$idx]:-} ]]; then
        speed_map[$idx]=$rate
      fi
    fi
  done < <(tac "$LOG_FILE" | head -n 4000)
fi

max_index=-1
for idx in "${!speed_map[@]}"; do
  if (( idx > max_index )); then
    max_index=$idx
  fi
done

gpu_count=0
(( ${#temp_arr[@]} > gpu_count )) && gpu_count=${#temp_arr[@]}
(( ${#fan_arr[@]}  > gpu_count )) && gpu_count=${#fan_arr[@]}
(( ${#bus_arr[@]}  > gpu_count )) && gpu_count=${#bus_arr[@]}
(( max_index + 1 > gpu_count )) && gpu_count=$((max_index + 1))

if (( gpu_count < 0 )); then
  gpu_count=0
fi

declare -a hs_arr temp_out fan_out bus_out
hs_arr=()
temp_out=()
fan_out=()
bus_out=()
have_temp=false
have_fan=false
have_bus=false

if $selected_any; then
  for idx_pos in "${!selected_order[@]}"; do
    actual_idx=${selected_order[$idx_pos]}
    if [[ -n ${skip_idx[$actual_idx]:-} ]]; then
      continue
    fi
    rate=${speed_map[$idx_pos]:-0}
    if [[ -z $rate ]]; then
      rate=0
    fi
    hs_arr+=("$rate")
    if [[ -n ${temp_arr[$actual_idx]:-} ]]; then
      temp_out+=("${temp_arr[$actual_idx]}")
      have_temp=true
    fi
    if [[ -n ${fan_arr[$actual_idx]:-} ]]; then
      fan_out+=("${fan_arr[$actual_idx]}")
      have_fan=true
    fi
    if [[ -n ${bus_arr[$actual_idx]:-} ]]; then
      bus_out+=("${bus_arr[$actual_idx]}")
      have_bus=true
    fi
  done
else
  for ((i=0; i<gpu_count; i++)); do
    if [[ -n ${skip_idx[$i]:-} ]]; then
      continue
    fi
    rate=${speed_map[$i]:-0}
    if [[ -z $rate ]]; then
      rate=0
    fi
    hs_arr+=("$rate")
    if [[ -n ${temp_arr[$i]:-} ]]; then
      temp_out+=("${temp_arr[$i]}")
      have_temp=true
    fi
    if [[ -n ${fan_arr[$i]:-} ]]; then
      fan_out+=("${fan_arr[$i]}")
      have_fan=true
    fi
    if [[ -n ${bus_arr[$i]:-} ]]; then
      bus_out+=("${bus_arr[$i]}")
      have_bus=true
    fi
  done
fi

if ! $have_temp; then
  temp_out=()
fi
if ! $have_fan; then
  fan_out=()
fi
if ! $have_bus; then
  bus_out=()
fi

if ((${#hs_arr[@]} > 0)); then
  sum_rate=$(printf '%s\n' "${hs_arr[@]}" | awk 'BEGIN { s = 0 } NF { s += $1 } END { if (NR == 0) printf "0"; else printf "%.3f", s }')
else
  sum_rate=0
fi

if uptime=$(get_proc_uptime); then
  :
elif [[ -f $LOG_FILE ]]; then
  now=$(date +%s)
  file_mtime=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
  (( uptime = now - file_mtime ))
  (( uptime < 0 )) && uptime=0
else
  uptime=0
fi

hs_json=$(array_to_json_numbers hs_arr 0)
temp_json=$(array_to_json_numbers temp_out 0)
fan_json=$(array_to_json_numbers fan_out 0)
bus_json=$(array_to_json_numbers bus_out 0)

if command -v jq >/dev/null 2>&1; then
  stats=$(jq -nc \
    --argjson hs "$hs_json" \
    --argjson temp "$temp_json" \
    --argjson fan "$fan_json" \
    --argjson uptime "$uptime" \
    --arg ver "$VERSION_VALUE" \
    --arg algo "$ALGO_VALUE" \
    --argjson bus "$bus_json" \
    --arg total "$sum_rate" \
    '{
      hs: $hs,
      hs_units: "p/s",
      temp: $temp,
      fan: $fan,
      uptime: $uptime,
      ver: $ver,
      ar: [0, 0],
      bus_numbers: $bus,
      total_khs: ($total | tonumber)
    } | if $algo == "" then . else . + {algo: $algo} end'
  )
else
  ver_json=$(json_escape "$VERSION_VALUE")
  stats="{\"hs\":$hs_json,\"hs_units\":\"p/s\",\"temp\":$temp_json,\"fan\":$fan_json,\"uptime\":$uptime,\"ver\":\"$ver_json\",\"ar\":[0,0],\"bus_numbers\":$bus_json,\"total_khs\":$sum_rate"
  if [[ -n $ALGO_VALUE ]]; then
    algo_json=$(json_escape "$ALGO_VALUE")
    stats+=",\"algo\":\"$algo_json\"}"
  else
    stats+='}'
  fi
fi

[[ -z $sum_rate ]] && sum_rate=0
[[ -z $stats ]] && stats='{"hs":[],"hs_units":"p/s","temp":[],"fan":[],"uptime":0,"ver":"","ar":[0,0],"total_khs":0}'

echo "$sum_rate"
echo "$stats"
