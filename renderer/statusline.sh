#!/usr/bin/env bash
set -euo pipefail

RED=$'\033[31m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
DIM=$'\033[2m'
RESET=$'\033[0m'

payload=$(cat)
if ! jq -e '.schema_version == 1' >/dev/null 2>&1 <<<"$payload"; then
  exit 0
fi

eval "$(jq -r '
  @sh "cwd=\(.cwd // "")",
  @sh "model_id=\(.model.id // "")",
  @sh "model_name=\(.model.display_name // .model.id // "")",
  @sh "effort=\(.effort.level // "")",
  @sh "runtime_state=\(.runtime.state // "")",
  @sh "task_progress=\(.runtime.task_progress // "")",
  @sh "ctx_used=\(.context_window.used_percentage // 0)",
  @sh "ctx_remaining=\(.context_window.remaining_percentage // 100)",
  @sh "ctx_window=\(.context_window.context_window_size // 0)",
  @sh "input_tokens=\(.context_window.total_input_tokens // 0)",
  @sh "cached_tokens=\(.context_window.cached_input_tokens // 0)",
  @sh "output_tokens=\(.context_window.total_output_tokens // 0)",
  @sh "backend_cost_micros=\(.cost.estimated_thread_cost_usd_micros // "")",
  @sh "five_hour_used=\([.rate_limits[]?.primary, .rate_limits[]?.secondary] | map(select(.window_minutes >= 285 and .window_minutes <= 315)) | first.used_percentage // "")",
  @sh "weekly_used=\([.rate_limits[]?.primary, .rate_limits[]?.secondary] | map(select(.window_minutes >= 9576 and .window_minutes <= 10584)) | first.used_percentage // "")"
' <<<"$payload")"

case "$model_name" in
  gpt-5.6-sol|gpt-5.6) model_name="GPT-5.6 Sol" ;;
  gpt-5.6-terra) model_name="GPT-5.6 Terra" ;;
  gpt-5.6-luna) model_name="GPT-5.6 Luna" ;;
  gpt-5.5) model_name="GPT-5.5" ;;
  gpt-5.4) model_name="GPT-5.4" ;;
  gpt-5.4-mini) model_name="GPT-5.4 mini" ;;
esac

join_parts() {
  local result="" part
  for part in "$@"; do
    [[ -n "$part" ]] || continue
    [[ -n "$result" ]] && result+=" · "
    result+="$part"
  done
  printf '%s' "$result"
}

make_bar() {
  local pct=${1%.*} width=${2:-10}
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  (( pct > 100 )) && pct=100
  local filled=$((pct * width / 100))
  local empty=$((width - filled))
  local color="$GREEN"
  (( pct >= 90 )) && color="$RED"
  if (( pct >= 70 && pct < 90 )); then color="$YELLOW"; fi
  printf '%s' "$color"
  printf "%${filled}s" | tr ' ' '█'
  printf "%${empty}s" | tr ' ' '░'
  printf '%s' "$RESET"
}

format_tokens() {
  awk -v n="${1:-0}" 'BEGIN {
    if (n >= 1000000) printf "%.1fm", n / 1000000;
    else if (n >= 1000) printf "%.1fk", n / 1000;
    else printf "%d", n;
  }'
}

model_prices() {
  case "$1" in
    gpt-5.6-sol|gpt-5.6) printf '4 0.4 20' ;;
    gpt-5.6-terra) printf '2 0.2 12' ;;
    gpt-5.6-luna) printf '0.2 0.02 1.2' ;;
    gpt-5.5) printf '5 0.5 30' ;;
    gpt-5.4) printf '2.5 0.25 15' ;;
    gpt-5.4-mini) printf '0.75 0.075 4.5' ;;
    *) return 1 ;;
  esac
}

api_equivalent_cost() {
  local prices input_price cached_price output_price uncached
  prices=$(model_prices "$model_id") || return 1
  read -r input_price cached_price output_price <<<"$prices"
  uncached=$((input_tokens - cached_tokens))
  (( uncached < 0 )) && uncached=0
  awk -v input="$uncached" -v cached="$cached_tokens" -v output="$output_tokens" \
    -v ip="$input_price" -v cp="$cached_price" -v op="$output_price" \
    'BEGIN { printf "%.6f", (input*ip + cached*cp + output*op) / 1000000 }'
}

repo_name=""
branch_line=""
if [[ -n "$cwd" ]]; then
  repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$repo_root" ]]; then
    repo_name=$(basename "$repo_root")
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
    if [[ "$branch" == "gitbutler/workspace" ]] && command -v but >/dev/null 2>&1; then
      branches=$(cd "$cwd" && but branch list --no-check --no-ahead --json 2>/dev/null \
        | jq -r '.appliedStacks[].heads[].name' 2>/dev/null \
        | paste -sd ',' - | sed 's/,/, /g' || true)
      branch_line="🌿 ${branches:-gitbutler/workspace}"
    elif [[ -n "$branch" ]]; then
      branch_line="🔀 $branch"
    fi
  else
    repo_name=$(basename "$cwd")
  fi
fi

line1=()
[[ -n "$repo_name" ]] && line1+=("📂 $repo_name")
[[ -n "$model_name" ]] && line1+=("🤖 $model_name")
[[ -n "$effort" ]] && line1+=("⚡ $effort")
[[ -n "$runtime_state" ]] && line1+=("$DIM$runtime_state$RESET")
[[ -n "$task_progress" ]] && line1+=("$task_progress")

line3=()
aud_rate=${CODEX_STATUSLINE_AUD_PER_USD:-1.55}
if [[ "$backend_cost_micros" =~ ^[0-9]+$ ]]; then
  cost_aud=$(awk -v micros="$backend_cost_micros" -v rate="$aud_rate" 'BEGIN { printf "%.2f", micros / 1000000 * rate }')
  line3+=("💸 A\$$cost_aud session")
elif (( input_tokens > 0 || output_tokens > 0 )) && cost_usd=$(api_equivalent_cost); then
  cost_aud=$(awk -v usd="$cost_usd" -v rate="$aud_rate" 'BEGIN { printf "%.2f", usd * rate }')
  line3+=("💸 ~A\$$cost_aud API equiv")
fi
if [[ "$five_hour_used" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  five_hour_int=${five_hour_used%.*}
  line3+=("⏱️ $(make_bar "$five_hour_int") ${five_hour_int}% 5h")
fi
if [[ "$weekly_used" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  weekly_int=${weekly_used%.*}
  line3+=("📅 $(make_bar "$weekly_int") ${weekly_int}% weekly")
fi

line4=()
if [[ "$ctx_used" =~ ^[0-9]+$ ]]; then
  context_text="💭 $(make_bar "$ctx_used") ${ctx_used}% ctx"
  if [[ "$ctx_window" =~ ^[0-9]+$ && "$ctx_window" -gt 0 ]]; then
    context_text+=" ($(format_tokens $((ctx_window * ctx_used / 100))) / $(format_tokens "$ctx_window"))"
  fi
  line4+=("$context_text")
fi
line4+=("🧠 $(format_tokens "$input_tokens") in / $(format_tokens "$output_tokens") out")

output=()
output+=("$(join_parts "${line1[@]}")")
[[ -n "$branch_line" ]] && output+=("$branch_line")
output+=("$(join_parts "${line3[@]}")")
output+=("$(join_parts "${line4[@]}")")

printf '%s\n' "${output[@]}"
