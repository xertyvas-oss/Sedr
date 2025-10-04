#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/h-manifest.conf"

BIN_PATH="$SCRIPT_DIR/golden-miner-pool-prover"
CONFIG_FILE="$CUSTOM_CONFIG_FILENAME"
LOG_FILE="${CUSTOM_LOG_BASENAME}.log"

[[ -x "$BIN_PATH" ]] || chmod +x "$BIN_PATH"
[[ -f "$CONFIG_FILE" ]] || {
  echo "ERROR: config file not found: $CONFIG_FILE" >&2
  exit 1
}

source "$CONFIG_FILE"

pubkey="${PUBKEY:-}"
rig_name="${RIG_NAME:-${WORKER_NAME:-}}"
label="${LABEL:-}"
local_ip="${LOCAL_IP:-}"
threads_per_card="${THREADS_PER_CARD:-}"
extra_args="${EXTRA_ARGS:-}"
extra_programs_raw="${EXTRA_PROGRAMS:-}"
devices="${DEVICES:-}"
devices_override=""
devices="${DEVICES:-}"

if [[ -z "$pubkey" ]]; then
  echo "ERROR: Pubkey is not configured. Check your flight sheet." >&2
  exit 1
fi

trim_whitespace() {
  local text="$1"
  text="${text#${text%%[!$'\t\n ']*}}"
  text="${text%${text##*[!$'\t\n ']}}"
  printf '%s' "$text"
}

extra_programs=()
if [[ -n "$extra_programs_raw" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    line=$(trim_whitespace "$line")
    [[ -z "$line" ]] && continue
    extra_programs+=("$line")
  done <<< "$(printf '%s\n' "$extra_programs_raw")"
fi

extra_program_pids=()

cleanup() {
  if ((${#extra_program_pids[@]})); then
    for pid in "${extra_program_pids[@]}"; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" 2>/dev/null || true
      fi
    done
  fi
}

trap cleanup EXIT

start_additional_program() {
  local program_path="$1"

  if [[ -z "$program_path" ]]; then
    return
  fi

  if [[ ! -e "$program_path" ]]; then
    echo "WARNING: additional program not found: $program_path" >&2
    return
  fi

  if [[ -d "$program_path" ]]; then
    echo "WARNING: additional program path is a directory: $program_path" >&2
    return
  fi

  if [[ ! -x "$program_path" ]]; then
    if ! chmod +x "$program_path" 2>/dev/null; then
      echo "WARNING: unable to make additional program executable: $program_path" >&2
      return
    fi
  fi

  echo "Starting additional program: $program_path"
  "$program_path" &
  extra_program_pids+=($!)
}

nvtool_opts=()
nvtool_vals=()
miner_extra_args=()

add_nvtool_cmd() {
  local opt="$1"
  local value="$2"

  if [[ -z $value ]]; then
    echo "WARNING: $opt requires a numeric value" >&2
    return
  fi

  if [[ ! $value =~ ^-?[0-9]+$ ]]; then
    echo "WARNING: ignoring $opt with non-numeric value '$value'" >&2
    return
  fi

  nvtool_opts+=("$opt")
  nvtool_vals+=("$value")
}

if [[ -n "$extra_args" ]]; then
  eval "set -- $extra_args"
  while (($#)); do
    token=$1
    shift

    case $token in
      nvtool)
        if (($# == 0)); then
          miner_extra_args+=("nvtool")
          break
        fi
        opt=$1
        shift

        if [[ $opt == --setcore=* || $opt == --setmem=* || $opt == --setmemoffset=* || $opt == --setcoreoffset=* || $opt == --setclocks=* || $opt == --setpl=* ]]; then
          value=${opt#*=}
          opt=${opt%%=*}
          add_nvtool_cmd "$opt" "$value"
          continue
        fi

        case $opt in
          --setcore|--setmem|--setmemoffset|--setcoreoffset|--setclocks|--setpl)
            if (($# == 0)); then
              echo "WARNING: $opt requires a numeric value" >&2
              continue
            fi
            value=$1
            shift
            add_nvtool_cmd "$opt" "$value"
            continue
            ;;
          *)
            miner_extra_args+=("nvtool" "$opt")
            continue
            ;;
        esac
        ;;
      --setcore|--setmem|--setmemoffset|--setcoreoffset|--setclocks|--setpl)
        if (($# == 0)); then
          echo "WARNING: $token requires a numeric value" >&2
          continue
        fi
        value=$1
        shift
        add_nvtool_cmd "$token" "$value"
        continue
        ;;
      --setcore=*|--setmem=*|--setmemoffset=*|--setcoreoffset=*|--setclocks=*|--setpl=*)
        opt=${token%%=*}
        value=${token#*=}
        add_nvtool_cmd "$opt" "$value"
        continue
        ;;
      -d)
        if (($# == 0)); then
          echo "WARNING: -d requires a value" >&2
        else
          devices_override=$1
          shift
        fi
        continue
        ;;
      -d*)
        value=${token#-d}
        if [[ -z $value ]]; then
          echo "WARNING: -d requires a value" >&2
        else
          devices_override=$value
        fi
        continue
        ;;
      --devices)
        if (($# == 0)); then
          echo "WARNING: --devices requires a value" >&2
        else
          devices_override=$1
          shift
        fi
        continue
        ;;
      --devices=*)
        devices_override=${token#*=}
        continue
        ;;
      *)
        miner_extra_args+=("$token")
        ;;
    esac
  done
fi

if [[ -n $devices_override ]]; then
  devices=$devices_override
fi

launch_env=()
if [[ -n "$devices" ]]; then
  normalized_devices=${devices//[[:space:]]/}
  if [[ $normalized_devices =~ ^[0-9,]+$ ]]; then
    launch_env+=("CUDA_VISIBLE_DEVICES=$normalized_devices")
    launch_env+=("NVIDIA_VISIBLE_DEVICES=$normalized_devices")
    launch_env+=("GPU_DEVICE_ORDINAL=$normalized_devices")
    launch_env+=("ROCR_VISIBLE_DEVICES=$normalized_devices")
  else
    echo "WARNING: ignoring invalid device list '$devices'" >&2
  fi
fi

if ((${#nvtool_opts[@]})); then
  if command -v nvtool >/dev/null 2>&1; then
    for idx in "${!nvtool_opts[@]}"; do
      opt="${nvtool_opts[$idx]}"
      value="${nvtool_vals[$idx]}"
      echo "Applying nvtool $opt $value"
      if ! nvtool "$opt" "$value"; then
        echo "WARNING: command failed: nvtool $opt $value" >&2
      fi
    done
  else
    echo "WARNING: nvtool not found in PATH, skipping clock adjustments" >&2
  fi
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

if ((${#extra_programs[@]})); then
  for program in "${extra_programs[@]}"; do
    start_additional_program "$program"
  done
fi

cmd=("$BIN_PATH" --pubkey "$pubkey")
[[ -n "$threads_per_card" ]] && cmd+=(--threads-per-card "$threads_per_card")
[[ -n "$rig_name" ]] && cmd+=(--name "$rig_name")
[[ -n "$label" ]] && cmd+=(--label "$label")
[[ -n "$local_ip" ]] && cmd+=(--local-ip "$local_ip")

if ((${#miner_extra_args[@]})); then
  for extra_arg in "${miner_extra_args[@]}"; do
    cmd+=("$extra_arg")
  done
fi

display_cmd=()
if ((${#launch_env[@]})); then
  display_cmd+=(env "${launch_env[@]}")
fi
display_cmd+=("${cmd[@]}")

printf 'Starting %s with command:' "$CUSTOM_NAME"
for arg in "${display_cmd[@]}"; do
  printf ' %q' "$arg"
done
printf '\n'

set +e
if ((${#launch_env[@]})); then
  env "${launch_env[@]}" "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
else
  "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
fi
exit_code=${PIPESTATUS[0]}
set -e

exit $exit_code
