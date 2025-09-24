#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/h-manifest.conf"

error() {
  echo "ERROR: $*" >&2
  return 1
}

warn() {
  echo "WARNING: $*" >&2
}

[[ -z "${CUSTOM_CONFIG_FILENAME:-}" ]] && error "CUSTOM_CONFIG_FILENAME is not set"
[[ -z "${CUSTOM_TEMPLATE:-}" ]] && error "CUSTOM_TEMPLATE (pubkey) is empty"

substitute_placeholders() {
  local value="$1"
  value="${value//%WORKER_NAME%/${WORKER_NAME:-}}"
  value="${value//%WORKER_ID%/${WORKER_ID:-}}"
  value="${value//%FARM_ID%/${FARM_ID:-}}"
  echo "$value"
}

set_named_option() {
  local key="$1"
  local value="$2"
  case "${key,,}" in
    pubkey)
      [[ -n "$value" ]] && PUBKEY="$value"
      return 0
      ;;
    name)
      [[ -n "$value" ]] && RIG_NAME="$value"
      return 0
      ;;
    label)
      [[ -n "$value" ]] && LABEL="$value"
      return 0
      ;;
    local_ip|local-ip)
      [[ -n "$value" ]] && LOCAL_IP="$value"
      return 0
      ;;
    threads|threads_per_card|threads-per-card|tpc)
      [[ -n "$value" ]] && THREADS_PER_CARD="$value"
      return 0
      ;;
  esac
  return 1
}

process_assignment_token() {
  local token="$1"
  local key value

  if [[ $token == *=* ]]; then
    key=${token%%=*}
    value=${token#*=}
  elif [[ $token == *:* ]]; then
    key=${token%%:*}
    value=${token#*:}
  else
    return 1
  fi

  set_named_option "$key" "$value"
}

PUBKEY=""
RIG_NAME="${WORKER_NAME:-}"
LABEL=""
LOCAL_IP=""
THREADS_PER_CARD=""
EXTRA_ARGS="${CUSTOM_USER_CONFIG:-}"
EXTRA_PROGRAMS_LIST=()

raw_template=$(substitute_placeholders "$CUSTOM_TEMPLATE")
if [[ -n "$raw_template" ]]; then
  read -r -a template_tokens <<< "$raw_template"
  for token in "${template_tokens[@]}"; do
    [[ -z "$token" ]] && continue
    if ! process_assignment_token "$token"; then
      if [[ -z "$PUBKEY" ]]; then
        PUBKEY="$token"
      fi
    fi
  done
fi

raw_pass="${CUSTOM_PASS:-}"
if [[ -n "$raw_pass" ]]; then
  raw_pass=$(substitute_placeholders "$raw_pass")
  read -r -a pass_tokens <<< "$raw_pass"
  for token in "${pass_tokens[@]}"; do
    [[ -z "$token" ]] && continue
    process_assignment_token "$token"
  done
fi

if [[ -z "$PUBKEY" ]]; then
  error "Unable to determine pubkey from CUSTOM_TEMPLATE."
fi

if [[ -n "$EXTRA_ARGS" ]]; then
  eval "set -- $EXTRA_ARGS"
  remaining=()
  while (($#)); do
    token=$1
    shift
    case $token in
      --threads-per-card)
        if (($#)); then
          THREADS_PER_CARD=$1
          shift
        else
          warn "--threads-per-card requires a value"
        fi
        ;;
      --threads-per-card=*)
        THREADS_PER_CARD=${token#*=}
        ;;
      --name)
        if (($#)); then
          RIG_NAME=$1
          shift
        else
          warn "--name requires a value"
        fi
        ;;
      --name=*)
        RIG_NAME=${token#*=}
        ;;
      --label)
        if (($#)); then
          LABEL=$1
          shift
        else
          warn "--label requires a value"
        fi
        ;;
      --label=*)
        LABEL=${token#*=}
        ;;
      --local-ip)
        if (($#)); then
          LOCAL_IP=$1
          shift
        else
          warn "--local-ip requires a value"
        fi
        ;;
      --local-ip=*)
        LOCAL_IP=${token#*=}
        ;;
      RUN=*|run=*)
        value=${token#*=}
        value=${value%%[[:space:]]*}
        [[ -n "$value" ]] && EXTRA_PROGRAMS_LIST+=("$value")
        ;;
      RUN:*|run:*)
        value=${token#*:}
        value=${value%%[[:space:]]*}
        [[ -n "$value" ]] && EXTRA_PROGRAMS_LIST+=("$value")
        ;;
      *)
        remaining+=("$token")
        ;;
    esac
  done
  EXTRA_ARGS="${remaining[*]:-}"
fi

if ((${#EXTRA_PROGRAMS_LIST[@]})); then
  EXTRA_PROGRAMS_SERIALIZED=$(printf '%s\n' "${EXTRA_PROGRAMS_LIST[@]}")
else
  EXTRA_PROGRAMS_SERIALIZED=""
fi

mkdir -p "$(dirname "$CUSTOM_CONFIG_FILENAME")"
cat > "$CUSTOM_CONFIG_FILENAME" <<CFG
PUBKEY=$(printf '%q' "$PUBKEY")
RIG_NAME=$(printf '%q' "$RIG_NAME")
LABEL=$(printf '%q' "$LABEL")
LOCAL_IP=$(printf '%q' "$LOCAL_IP")
THREADS_PER_CARD=$(printf '%q' "$THREADS_PER_CARD")
EXTRA_ARGS=$(printf '%q' "$EXTRA_ARGS")
EXTRA_PROGRAMS=$(printf '%q' "$EXTRA_PROGRAMS_SERIALIZED")
CFG

chmod 600 "$CUSTOM_CONFIG_FILENAME"
