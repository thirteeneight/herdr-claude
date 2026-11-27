#!/usr/bin/env bash
# Claude Code status line: session cost, model, git, and context size with the prompt cache's state.
# Costs are list-price estimates from the transcript (main thread and subagents). Needs jq.
input=$(cat)
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
model_name=$(echo "$input" | jq -r '.model.display_name')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
dir_name=$(basename "$current_dir")
# --no-optional-locks: a status killed mid-refresh otherwise leaves .git/index.lock behind.
git_branch=$(cd "$current_dir" 2>/dev/null && git --no-optional-locks -c gc.auto=0 branch --show-current 2>/dev/null || echo '')
git_dirty=$(cd "$current_dir" 2>/dev/null && git --no-optional-locks -c gc.auto=0 status --porcelain 2>/dev/null | grep -q . && echo '1' || echo '')

# Optional Workwatch (ww) label, same switch as herdr-claude: {"workwatch": {"enabled": true}}.
config="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-claude/config.json"
ws_on=$(jq -r '.workwatch.enabled == true' "$config" 2>/dev/null)
ws_db="${WW_DIR:-$HOME/projects/.workwatch}/db.json"
workstream=''
if [ "$ws_on" = "true" ] && [ -n "$session_id" ] && [ -f "$ws_db" ]; then
  # Its claim first, then its latest open session entry.
  workstream=$(jq -r --arg s "$session_id" '
    [.workstreams[]? | . as $w
     | ((.sessions // []) | map(select(.id == $s and .endedAt == null)) | max_by(.lastSeenAt)) as $e
     | select($w.claim.session.id == $s or $e != null)
     | {w: $w, claimed: ($w.claim.session.id == $s), seen: ($e.lastSeenAt // "")}]
    | sort_by([.claimed, .seen]) | last // empty
    | "\(.w.id) \(.w.name // .w.title // "")"' "$ws_db" 2>/dev/null)
fi
ctx_total_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
# "-" stands in for absent fields: read collapses empty tab-separated columns.
read -r model_id cache_warm cache_exp cache_ttl recache < <(echo "$input" | jq -r '[
  (.model.id // "-"),
  (if .prompt_cache.warm == null then "-" else (.prompt_cache.warm | tostring) end),
  (.prompt_cache.expires_at // "-"), (.prompt_cache.ttl // "-"),
  (.prompt_cache.recache_tokens_if_cold // "-")] | map(tostring) | @tsv')
# Bar spans the autoCompactWindow set in settings.json.
ctx_cap=${STATUSLINE_CTX_CAP:-500000}

# [input, output, cache read] USD per million tokens; keep in step with PRICES in herdr-claude.
# Cache writes: 5m TTL = 1.25x input, 1h TTL = 2x input. Fast mode = 2x everything.
# shellcheck disable=SC2016
price_jq='
def price(m):
  if   m|test("fable-5-2")         then [8,40,0.2]
  elif m|test("fable-5-1")         then [10,50,0.25]
  elif m|test("fable")             then [10,50,1]
  elif m|test("opus-5-5")          then [4,20,0.2]
  elif m|test("opus-(5|4-[5-9])")  then [5,25,0.5]
  elif m|test("opus")              then [15,75,1.5]
  elif m|test("sonnet-5-5")        then [2,10,0.1]
  elif m|test("sonnet-5")          then [2,10,0.2]
  elif m|test("sonnet")            then [3,15,0.3]
  elif m|test("haiku-5")           then [0.1,0.5,0.01]
  elif m|test("haiku-4")           then [1,5,0.1]
  elif m|test("haiku")             then [0.8,4,0.08]
  else [0,0,0] end;'
# shellcheck disable=SC2016
cost_jq="$price_jq"'
def cost:
  .message as $m | $m.usage as $u | price($m.model // "") as $p
  | ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $cw1h
  | (($u.cache_creation.ephemeral_5m_input_tokens) // (($u.cache_creation_input_tokens // 0) - $cw1h)) as $cw5m
  | (if $u.speed == "fast" then 2 else 1 end)
    * (($u.input_tokens // 0) * $p[0] + ($u.output_tokens // 0) * $p[1]
       + $cw5m * $p[0] * 1.25 + $cw1h * $p[0] * 2
       + ($u.cache_read_input_tokens // 0) * $p[2]) / 1000000;
[.[] | select(.message.usage != null)] | unique_by(.message.id)
| {c: (map(cost) | add // 0),
   i: (map(.message.usage.input_tokens // 0) | add // 0),
   o: (map(.message.usage.output_tokens // 0) | add // 0),
   cw: (map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
   cr: (map(.message.usage.cache_read_input_tokens // 0) | add // 0)}'

usage_main='{}'; usage_sub='{}'
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  usage_main=$(grep -a cache_read_input_tokens "$transcript_path" 2>/dev/null | jq -s -c "$cost_jq" 2>/dev/null)
  sub_dir="${transcript_path%.jsonl}/subagents"
  if ls "$sub_dir"/*.jsonl >/dev/null 2>&1; then
    usage_sub=$(cat "$sub_dir"/*.jsonl | grep -a cache_read_input_tokens 2>/dev/null | jq -s -c "$cost_jq" 2>/dev/null)
  fi
fi
[ -z "$usage_main" ] && usage_main='{}'
[ -z "$usage_sub" ] && usage_sub='{}'

read -r cost sub_cost in_tok out_tok cache_tot < <(jq -n -r --argjson a "$usage_main" --argjson b "$usage_sub" \
  '[($a.c//0)+($b.c//0), ($b.c//0), ($a.i//0)+($b.i//0), ($a.o//0)+($b.o//0), ($a.cw//0)+($b.cw//0)+($a.cr//0)+($b.cr//0)] | @tsv')

fmt() { awk -v n="$1" 'BEGIN{if(n>=1000000)printf "%.1fM", n/1000000; else if(n>=1000)printf "%.1fk", n/1000; else printf "%d", n}'; }
bar() { awk -v p="$1" -v w=12 'BEGIN{if(p=="")p=0; f=int(p*w/100+0.5); if(f<0)f=0; if(f>w)f=w; s=""; for(i=0;i<f;i++)s=s"█"; for(i=f;i<w;i++)s=s"░"; print s}'; }
# BSD date takes -r epoch, GNU date takes -d @epoch.
hhmm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null; }

fmt_cost=$(awk -v c="$cost" 'BEGIN{printf "%.2f", c}')
fmt_sub_cost=$(awk -v c="$sub_cost" 'BEGIN{printf "%.2f", c}')

# Line 1 stays short so narrow windows keep it whole: price, model, then the workstream (name cut to 40).
line1=$(printf '\033[1;33m$%s\033[0m \033[90m·\033[0m \033[35m%s\033[0m' "$fmt_cost" "$model_name")
if [ -n "$workstream" ]; then
  ws_text=$(printf '%s' "$workstream" | awk '{if(length($0)>40)print substr($0,1,39)"…"; else print}')
  line1="$line1 $(printf '\033[90m·\033[0m \033[1;36m%s\033[0m' "$ws_text")"
elif [ "$ws_on" = "true" ]; then
  line1="$line1 $(printf '\033[90m· no workstream\033[0m')"
fi

if [ -n "$git_branch" ]; then
  dirty=''; [ -n "$git_dirty" ] && dirty=$(printf ' \033[33m✗\033[0m')
  line2=$(printf '\033[1;32m➜\033[0m  \033[36m%s\033[0m \033[1;34mgit:(\033[31m%s\033[34m)\033[0m%s' "$dir_name" "$git_branch" "$dirty")
else
  line2=$(printf '\033[1;32m➜\033[0m  \033[36m%s\033[0m' "$dir_name")
fi
agents=''
awk -v c="$sub_cost" 'BEGIN{exit !(c>0)}' && agents=" · agents \$$fmt_sub_cost"
line2="$line2 $(printf '\033[90m(in %s · out %s · cache %s%s)\033[0m' "$(fmt "$in_tok")" "$(fmt "$out_tok")" "$(fmt "$cache_tot")" "$agents")"

# Zones: green <200k, amber 200-400k, red >400k or a cold cache at 150k+.
# A cold resume rewrites the context at the cache-write rate (2x input on the 1h TTL).
if [ "${ctx_total_in:-0}" -gt 0 ] 2>/dev/null; then
  read -r in_price read_price < <(jq -n -r --arg m "$model_id" "$price_jq"' price($m) | "\(.[0]) \(.[2])"')
  [ "$recache" = "-" ] && recache=$ctx_total_in
  write_mult=2; [ "$cache_ttl" = "5m" ] && write_mult=1.25
  next_cost=$(awk -v t="$ctx_total_in" -v p="$read_price" 'BEGIN{printf "%.2f", t*p/1e6}')
  cold_cost=$(awk -v t="$recache" -v p="$in_price" -v w="$write_mult" 'BEGIN{printf "%.2f", t*p*w/1e6}')
  pct=$(awk -v t="$ctx_total_in" -v c="$ctx_cap" 'BEGIN{printf "%d", t*100/c}')
  if [ "$cache_warm" = "false" ]; then
    if [ "$ctx_total_in" -ge 150000 ]; then zc='\033[31m'; advice='/compact or hand over before continuing'; else zc='\033[90m'; advice=''; fi
    line3=$(printf "${zc}Ctx %s\033[0m \033[90m·\033[0m ${zc}cache cold\033[0m \033[90m· resume rewrites %s ~\$%s\033[0m" "$(fmt "$ctx_total_in")" "$(fmt "$recache")" "$cold_cost")
  else
    if [ "$ctx_total_in" -gt 400000 ]; then zc='\033[31m'; advice='/compact or hand over now'
    elif [ "$ctx_total_in" -ge 200000 ]; then zc='\033[33m'; advice='compact at next milestone'
    else zc='\033[32m'; advice=''; fi
    cache_txt=''
    if [ "$cache_exp" != "-" ]; then cache_txt=" · cache warm til $(hhmm "$cache_exp")"; fi
    line3=$(printf "${zc}Ctx %s\033[0m [${zc}%s\033[0m] \033[90mnext turn ~\$%s%s\033[0m" "$(fmt "$ctx_total_in")" "$(bar "$pct")" "$next_cost" "$cache_txt")
  fi
  [ -n "$advice" ] && line3="$line3 $(printf "\033[90m·\033[0m ${zc}%s\033[0m" "$advice")"
else
  line3=$(printf '\033[90mCtx: no messages yet\033[0m')
fi
printf '%s\n%s\n%s' "$line1" "$line2" "$line3"
