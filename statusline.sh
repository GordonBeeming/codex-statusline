#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
CODEX_STATE_DB="${CODEX_STATUSLINE_STATE_DB:-${CODEX_HOME}/state_5.sqlite}"
CODEX_SESSIONS_DIR="${CODEX_STATUSLINE_SESSIONS_DIR:-${CODEX_HOME}/sessions}"
CURRENCY_CONFIG_PATH="${CODEX_STATUSLINE_CURRENCY_CONFIG:-${HOME}/.codex-statusline.json}"
CURRENCY_CODE="${CODEX_STATUSLINE_CURRENCY:-AUD}"
CURRENCY_RATE_TTL_SECONDS="${CODEX_STATUSLINE_CURRENCY_RATE_TTL_SECONDS:-86400}"
AUD_PER_USD_FALLBACK="${CODEX_STATUSLINE_AUD_PER_USD:-1.55}"
CONTEXT_WINDOW_FALLBACK="${CODEX_STATUSLINE_CONTEXT_WINDOW:-258400}"

RED='\033[31m'
YELLOW='\033[33m'
GREEN='\033[32m'
DIM='\033[2m'
RESET='\033[0m'

now_epoch() {
  date +%s
}

json_get() {
  local filter=$1
  jq -r "$filter // empty" 2>/dev/null || true
}

sql_ro() {
  local sql=$1
  [[ -f "$CODEX_STATE_DB" ]] || return 1
  sqlite3 "file:${CODEX_STATE_DB}?mode=ro" "$sql" 2>/dev/null || true
}

shell_quote_sql() {
  printf "%s" "$1" | sed "s/'/''/g"
}

make_bar() {
  local pct=$1
  local width=${2:-10}
  [[ "$pct" =~ ^-?[0-9]+$ ]] || pct=0
  if (( pct > 100 )); then pct=100; fi
  if (( pct < 0 )); then pct=0; fi

  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local bar_color="$GREEN"
  if (( pct >= 90 )); then
    bar_color="$RED"
  elif (( pct >= 70 )); then
    bar_color="$YELLOW"
  fi

  local bar
  bar=$(printf "%${filled}s" | tr ' ' '█')$(printf "%${empty}s" | tr ' ' '░')
  printf '%b%s%b' "$bar_color" "$bar" "$RESET"
}

format_cost() {
  local cost_usd=$1
  local symbol=${2:-A$}
  local rate=${3:-1}
  local formatted
  formatted=$(awk -v cost="$cost_usd" -v symbol="$symbol" -v rate="$rate" 'BEGIN { printf "%s%.2f", symbol, (cost + 0) * (rate + 0) }')

  local converted_cost_int
  converted_cost_int=$(awk -v cost="$cost_usd" -v rate="$rate" 'BEGIN { printf "%d", (cost + 0) * (rate + 0) }')
  if (( converted_cost_int >= 50 )); then
    printf '%b%s%b' "$RED" "$formatted" "$RESET"
  elif (( converted_cost_int >= 25 )); then
    printf '%b%s%b' "$YELLOW" "$formatted" "$RESET"
  else
    printf '%s' "$formatted"
  fi
}

join_parts() {
  local sep=" · "
  local result=""
  local part
  for part in "$@"; do
    [[ -n "$part" ]] || continue
    if [[ -n "$result" ]]; then
      result="${result}${sep}${part}"
    else
      result="$part"
    fi
  done
  printf '%s' "$result"
}

current_cwd() {
  pwd -P 2>/dev/null || pwd 2>/dev/null || printf '%s' ""
}

repo_context() {
  local cwd=$1
  local toplevel=""
  local repo_name=""
  local in_git_repo=false

  if [[ -n "$cwd" ]]; then
    toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
  fi

  if [[ -n "$toplevel" ]]; then
    repo_name=$(basename "$toplevel")
    in_git_repo=true
  elif [[ -n "$cwd" ]]; then
    repo_name=$(basename "$cwd")
  fi

  printf '%s\t%s\t%s\n' "$repo_name" "$in_git_repo" "$toplevel"
}

branch_info() {
  local cwd=$1
  local current_branch=""
  current_branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)

  if [[ "$current_branch" == "gitbutler/workspace" ]]; then
    local branches=""
    if command -v but >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      branches=$(cd "$cwd" && but branch list --no-check --no-ahead --json 2>/dev/null \
        | jq -r '.appliedStacks[].heads[].name' 2>/dev/null \
        | paste -sd ',' - 2>/dev/null \
        | sed 's/,/, /g' || true)
    fi

    if [[ -n "$branches" ]]; then
      printf '🌿 %s' "$branches"
    else
      printf '🌿 gitbutler/workspace'
    fi
  elif [[ -n "$current_branch" ]]; then
    printf '🔀 %s' "$current_branch"
  fi
}

latest_thread_row() {
  local cwd=$1
  local cwd_sql
  cwd_sql=$(shell_quote_sql "$cwd")

  sql_ro "SELECT id || char(9) || COALESCE(model, '') || char(9) || COALESCE(reasoning_effort, '') || char(9) || rollout_path || char(9) || created_at_ms || char(9) || updated_at_ms FROM threads WHERE cwd = '${cwd_sql}' ORDER BY updated_at_ms DESC LIMIT 1;"
}

latest_session_file() {
  local row=$1
  local rollout_path=""
  local session_files=()

  rollout_path=$(printf '%s' "$row" | awk -F '\t' '{print $4}')
  if [[ -n "$rollout_path" && -f "$rollout_path" ]]; then
    printf '%s' "$rollout_path"
    return 0
  fi

  [[ -n "${CODEX_SESSIONS_DIR:-}" && -d "$CODEX_SESSIONS_DIR" ]] || return 0

  mapfile -d '' -t session_files < <(
    find "$CODEX_SESSIONS_DIR" -type f -name '*.jsonl' -print0 2>/dev/null
  )

  [[ ${#session_files[@]} -gt 0 ]] || return 0

  # shellcheck disable=SC2012
  ls -t "${session_files[@]}" 2>/dev/null | head -1
}

token_payload_from_file() {
  local file=$1
  [[ -f "$file" ]] || return 0
  tail -1000 "$file" 2>/dev/null \
    | jq -sc 'map(select(.type == "event_msg" and .payload.type == "token_count")) | last | .payload // {}' 2>/dev/null || printf '{}'
}

session_meta_from_file() {
  local file=$1
  [[ -f "$file" ]] || return 0
  head -1 "$file" 2>/dev/null \
    | jq -c 'select(.type == "session_meta") | .payload // {}' 2>/dev/null || printf '{}'
}

model_display_name() {
  local model=$1
  case "$model" in
    gpt-5.5) printf 'GPT-5.5' ;;
    gpt-5.4) printf 'GPT-5.4' ;;
    gpt-5.4-mini) printf 'GPT-5.4 mini' ;;
    gpt-5.3-codex) printf 'GPT-5.3 Codex' ;;
    gpt-5.3-codex-spark) printf 'GPT-5.3 Codex Spark' ;;
    "") printf '' ;;
    *) printf '%s' "$model" ;;
  esac
}

effort_display() {
  local effort=$1
  case "$effort" in
    low) printf '⚡ %b%s%b' "$DIM" "$effort" "$RESET" ;;
    medium) printf '⚡ %s' "$effort" ;;
    high) printf '⚡ %b%s%b' "$YELLOW" "$effort" "$RESET" ;;
    xhigh|max) printf '⚡ %b%s%b' "$RED" "$effort" "$RESET" ;;
    "") printf '' ;;
    *) printf '⚡ %s' "$effort" ;;
  esac
}

symbol_for_currency() {
  local code
  code=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  case "$code" in
    USD) printf '$' ;;
    EUR) printf '€' ;;
    GBP) printf '£' ;;
    JPY|CNY) printf '¥' ;;
    KRW) printf '₩' ;;
    INR) printf '₹' ;;
    RUB) printf '₽' ;;
    BRL) printf 'R$' ;;
    ZAR) printf 'R' ;;
    CAD) printf 'CA$' ;;
    AUD) printf 'A$' ;;
    CHF) printf 'CHF' ;;
    SEK|NOK|DKK) printf 'kr' ;;
    PLN) printf 'zł' ;;
    TRY) printf '₺' ;;
    MXN) printf 'MX$' ;;
    NZD) printf 'NZ$' ;;
    *) printf '%s' "$code" ;;
  esac
}

currency_config_value() {
  local key=$1
  [[ -f "$CURRENCY_CONFIG_PATH" ]] || return 0
  jq -r --arg key "$key" '.[$key] // empty' "$CURRENCY_CONFIG_PATH" 2>/dev/null || true
}

write_currency_config() {
  local code=$1
  local rate=$2
  local updated=$3
  local config_dir
  local tmp_file

  config_dir=$(dirname -- "$CURRENCY_CONFIG_PATH")
  if ! mkdir -p -- "$config_dir" 2>/dev/null; then
    printf 'warning: failed to create currency config directory: %s\n' "$config_dir" >&2
    return 0
  fi

  if ! tmp_file=$(mktemp "${CURRENCY_CONFIG_PATH}.tmp.XXXXXX" 2>/dev/null); then
    printf 'warning: failed to create temporary currency config file: %s\n' "$CURRENCY_CONFIG_PATH" >&2
    return 0
  fi

  if ! jq -n \
    --arg currency "$code" \
    --argjson cached_rate "$rate" \
    --arg rate_updated "$updated" \
    '{currency: $currency, cached_rate: $cached_rate, rate_updated: $rate_updated}' \
    > "$tmp_file" 2>/dev/null; then
    printf 'warning: failed to write currency config: %s\n' "$CURRENCY_CONFIG_PATH" >&2
    rm -f -- "$tmp_file"
    return 0
  fi

  if ! mv -f -- "$tmp_file" "$CURRENCY_CONFIG_PATH" 2>/dev/null; then
    printf 'warning: failed to replace currency config: %s\n' "$CURRENCY_CONFIG_PATH" >&2
    rm -f -- "$tmp_file"
  fi
}

parse_iso_epoch_seconds() {
  local timestamp=$1
  local parsed

  if parsed=$(date -d "$timestamp" +%s 2>/dev/null); then
    printf '%s\n' "$parsed"
    return 0
  fi

  if parsed=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null); then
    printf '%s\n' "$parsed"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$timestamp" <<'PY'
import datetime
import sys

value = sys.argv[1]
if value.endswith("Z"):
    value = value[:-1] + "+00:00"
print(int(datetime.datetime.fromisoformat(value).timestamp()))
PY
    return 0
  fi

  return 1
}

local_midnight_epoch_seconds() {
  local midnight

  if midnight=$(date -d 'today 00:00:00' +%s 2>/dev/null); then
    printf '%s\n' "$midnight"
    return 0
  fi

  if midnight=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null); then
    printf '%s\n' "$midnight"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import time

now = time.localtime()
print(int(time.mktime((now.tm_year, now.tm_mon, now.tm_mday, 0, 0, 0, now.tm_wday, now.tm_yday, now.tm_isdst))))
PY
    return 0
  fi

  return 1
}

currency_info() {
  local code
  code=$(currency_config_value currency)
  code=${code:-$CURRENCY_CODE}
  code=$(printf '%s' "$code" | tr '[:lower:]' '[:upper:]')

  local symbol
  symbol=$(symbol_for_currency "$code")

  if [[ "$code" == "USD" ]]; then
    printf '%s\t%s\t%s\n' "$code" "$symbol" "1"
    return 0
  fi

  local cached_rate rate_updated updated_epoch now
  cached_rate=$(currency_config_value cached_rate)
  rate_updated=$(currency_config_value rate_updated)
  now=$(now_epoch)

  if [[ "$cached_rate" =~ ^[0-9]+([.][0-9]+)?$ && -n "$rate_updated" ]]; then
    updated_epoch=$(parse_iso_epoch_seconds "$rate_updated" 2>/dev/null || true)
    if [[ "$updated_epoch" =~ ^[0-9]+$ && $(( now - updated_epoch )) -lt "$CURRENCY_RATE_TTL_SECONDS" ]]; then
      printf '%s\t%s\t%s\n' "$code" "$symbol" "$cached_rate"
      return 0
    fi
  fi

  local fetched=""
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    fetched=$(curl -fsSL --max-time 2 'https://open.er-api.com/v6/latest/USD' 2>/dev/null \
      | jq -r --arg code "$code" '.rates[$code] // empty' 2>/dev/null || true)
  fi

  if [[ "$fetched" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    write_currency_config "$code" "$fetched" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '%s\t%s\t%s\n' "$code" "$symbol" "$fetched"
    return 0
  fi

  if [[ "$cached_rate" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s\t%s\t%s\n' "$code" "$symbol" "$cached_rate"
    return 0
  fi

  if [[ "$code" == "AUD" ]]; then
    printf '%s\t%s\t%s\n' "$code" "$symbol" "$AUD_PER_USD_FALLBACK"
    return 0
  fi

  printf 'warning: no exchange rate available for %s; falling back to USD\n' "$code" >&2
  printf '%s\t%s\t%s\n' "USD" "$" "1"
}

model_price_usd_per_million() {
  local model=$1
  case "$model" in
    gpt-5.5) printf '5.00 0.50 30.00' ;;
    gpt-5.4) printf '2.50 0.25 15.00' ;;
    gpt-5.4-mini) printf '0.75 0.075 4.50' ;;
    *)
      local upper
      upper=$(printf '%s' "$model" | tr '[:lower:]' '[:upper:]' | tr '.-' '__')
      local input_var="CODEX_STATUSLINE_PRICE_${upper}_INPUT"
      local cached_var="CODEX_STATUSLINE_PRICE_${upper}_CACHED_INPUT"
      local output_var="CODEX_STATUSLINE_PRICE_${upper}_OUTPUT"
      if [[ -n "${!input_var:-}" && -n "${!cached_var:-}" && -n "${!output_var:-}" ]]; then
        printf '%s %s %s' "${!input_var}" "${!cached_var}" "${!output_var}"
      else
        printf '0 0 0'
      fi
      ;;
  esac
}

cost_usd_from_usage() {
  local model=$1
  local input_tokens=${2:-0}
  local cached_input_tokens=${3:-0}
  local output_tokens=${4:-0}

  local prices input_price cached_price output_price
  prices=$(model_price_usd_per_million "$model")
  read -r input_price cached_price output_price <<< "$prices"

  awk \
    -v input="$input_tokens" \
    -v cached="$cached_input_tokens" \
    -v output="$output_tokens" \
    -v input_price="$input_price" \
    -v cached_price="$cached_price" \
    -v output_price="$output_price" \
    'BEGIN {
      uncached = input - cached;
      if (uncached < 0) uncached = 0;
      usd = (uncached * input_price + cached * cached_price + output * output_price) / 1000000;
      printf "%.6f", usd;
    }'
}

daily_rollout_paths() {
  [[ -f "$CODEX_STATE_DB" ]] || return 0
  local start_ms end_ms
  start_ms=$(local_midnight_epoch_seconds) || return 0
  start_ms=$(( start_ms * 1000 ))
  end_ms=$(( start_ms + 86400000 ))

  sql_ro "SELECT rollout_path FROM threads WHERE created_at_ms >= ${start_ms} AND created_at_ms < ${end_ms} AND rollout_path != '' ORDER BY created_at_ms ASC;"
}

usage_field() {
  local payload=$1
  local filter=$2
  printf '%s' "$payload" | jq -r "$filter // 0" 2>/dev/null || printf '0'
}

daily_cost_usd() {
  local total="0"
  local path payload meta model input cached output cost

  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    payload=$(token_payload_from_file "$path")
    [[ "$payload" != "{}" ]] || continue
    meta=$(session_meta_from_file "$path")
    model=$(printf '%s' "$meta" | json_get '.model // empty')
    model=${model:-gpt-5.5}
    input=$(usage_field "$payload" '.info.total_token_usage.input_tokens')
    cached=$(usage_field "$payload" '.info.total_token_usage.cached_input_tokens')
    output=$(usage_field "$payload" '.info.total_token_usage.output_tokens')
    cost=$(cost_usd_from_usage "$model" "$input" "$cached" "$output")
    total=$(awk -v a="$total" -v b="$cost" 'BEGIN { printf "%.6f", a + b }')
  done < <(daily_rollout_paths)

  printf '%s' "$total"
}

format_tokens_k() {
  local tokens=${1:-0}
  awk -v tokens="$tokens" 'BEGIN {
    if (tokens >= 1000000) printf "%.1fm", tokens / 1000000;
    else printf "%dk", tokens / 1000;
  }'
}

main() {
  command -v jq >/dev/null 2>&1 || {
    printf 'codex-statusline requires jq\n'
    return 1
  }

  local cwd
  cwd=$(current_cwd)

  local row model effort rollout_path created_at_ms updated_at_ms
  row=$(latest_thread_row "$cwd" || true)
  IFS=$'\t' read -r _ model effort rollout_path created_at_ms updated_at_ms <<< "$row"

  local session_file
  session_file=$(latest_session_file "$row")

  local payload meta
  payload=$(token_payload_from_file "$session_file")
  meta=$(session_meta_from_file "$session_file")

  if [[ -z "$model" ]]; then
    model=$(printf '%s' "$meta" | json_get '.model // empty')
  fi
  model=${model:-${CODEX_STATUSLINE_MODEL:-gpt-5.5}}
  effort=${effort:-${CODEX_STATUSLINE_REASONING_EFFORT:-}}

  local repo_name in_git_repo toplevel
  IFS=$'\t' read -r repo_name in_git_repo toplevel <<< "$(repo_context "$cwd")"

  local branch
  branch=$(branch_info "$cwd")

  local total_input cached_input total_output context_window ctx_pct ctx_left_pct primary_pct resets_at latest_context_tokens
  total_input=$(usage_field "$payload" '.info.total_token_usage.input_tokens')
  cached_input=$(usage_field "$payload" '.info.total_token_usage.cached_input_tokens')
  total_output=$(usage_field "$payload" '.info.total_token_usage.output_tokens')
  latest_context_tokens=$(usage_field "$payload" '.info.last_token_usage.input_tokens')
  context_window=$(usage_field "$payload" '.info.model_context_window')
  [[ "$context_window" == "0" ]] && context_window="$CONTEXT_WINDOW_FALLBACK"

  ctx_pct=$(awk -v total="$latest_context_tokens" -v window="$context_window" 'BEGIN {
    if (window <= 0) print 0;
    else printf "%d", (total * 100) / window;
  }')
  if [[ "$ctx_pct" =~ ^[0-9]+$ && "$ctx_pct" -gt 100 ]]; then
    ctx_pct=100
  fi
  ctx_left_pct=$(( 100 - ctx_pct ))

  primary_pct=$(usage_field "$payload" '.rate_limits.primary.used_percent')
  primary_pct=${primary_pct%.*}
  resets_at=$(usage_field "$payload" '.rate_limits.primary.resets_at')

  local currency_symbol rate session_cost_usd daily_cost_total_usd
  IFS=$'\t' read -r _ currency_symbol rate <<< "$(currency_info)"
  session_cost_usd=$(cost_usd_from_usage "$model" "$total_input" "$cached_input" "$total_output")
  daily_cost_total_usd=$(daily_cost_usd)

  local line1_parts=()
  if [[ -n "$repo_name" ]]; then
    if [[ "$in_git_repo" == "true" ]]; then
      line1_parts+=("📂 ${repo_name}")
      [[ -n "$branch" ]] && line1_parts+=("$branch")
    else
      line1_parts+=("📁 ${repo_name}")
      line1_parts+=("$(printf '%b🚫 no git%b' "$DIM" "$RESET")")
    fi
  fi

  local line2_parts=()
  local model_label effort_label
  model_label=$(model_display_name "$model")
  effort_label=$(effort_display "$effort")
  [[ -n "$model_label" ]] && line2_parts+=("🤖 ${model_label}")
  [[ -n "$effort_label" ]] && line2_parts+=("$effort_label")

  local line3_parts=()
  line3_parts+=("💸 $(format_cost "$session_cost_usd" "$currency_symbol" "$rate") session")
  line3_parts+=("💰 $(format_cost "$daily_cost_total_usd" "$currency_symbol" "$rate") today")
  if [[ "$primary_pct" =~ ^[0-9]+$ && "$primary_pct" -gt 0 ]]; then
    local rate_bar time_left
    rate_bar=$(make_bar "$primary_pct" 10)
    time_left=""
    if [[ "$resets_at" =~ ^[0-9]+$ && "$resets_at" -gt 0 ]]; then
      local remaining hours_left mins_left
      remaining=$(( resets_at - $(now_epoch) ))
      if (( remaining > 0 )); then
        hours_left=$(( remaining / 3600 ))
        mins_left=$(( (remaining % 3600) / 60 ))
        time_left=" ${hours_left}h${mins_left}m left"
      fi
    fi
    line3_parts+=("⏱️ ${rate_bar} ${primary_pct}%${time_left}")
  elif [[ -n "${created_at_ms:-}" && -n "${updated_at_ms:-}" ]]; then
    local duration_secs hours mins
    duration_secs=$(( (updated_at_ms - created_at_ms) / 1000 ))
    if (( duration_secs > 0 )); then
      hours=$(( duration_secs / 3600 ))
      mins=$(( (duration_secs % 3600) / 60 ))
      line3_parts+=("⏱️ ${hours}h${mins}m")
    fi
  fi

  local line4_parts=()
  if [[ "$ctx_pct" =~ ^[0-9]+$ && "$ctx_pct" -gt 0 ]]; then
    line4_parts+=("💭 $(make_bar "$ctx_pct" 10) ${ctx_pct}% used · ${ctx_left_pct}% left ($(format_tokens_k "$latest_context_tokens") / $(format_tokens_k "$context_window"))")
  fi

  local output=""
  local line
  for line in \
    "$(join_parts "${line1_parts[@]}")" \
    "$(join_parts "${line2_parts[@]}")" \
    "$(join_parts "${line3_parts[@]}")" \
    "$(join_parts "${line4_parts[@]}")"; do
    [[ -n "$line" ]] || continue
    [[ -n "$output" ]] && output+=$'\n'
    output+="$line"
  done

  printf '%b\n' "$output"
}

main "$@"
