#!/usr/bin/env bash
# Build and post a WeCom group-bot markdown notification for one workflow run.
# Every exit path is 0 — a notification must never turn a green pipeline red.
# Inputs arrive as env vars mapped in action.yml. DRY_RUN=1 prints the payload
# instead of sending (used by tests/notify-wecom-test.sh).
set -uo pipefail

note() { echo "::warning::notify-wecom: $*"; exit 0; }

if [ -z "${WECOM_WEBHOOK_URL:-}" ]; then
  echo "::warning::notify-wecom: WECOM_WEBHOOK_URL is not set, notification skipped"
  {
    echo ''
    echo '> ⚠️ 未配置 WECOM_WEBHOOK_URL，本次企业微信通知未发送'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi
# The webhook is a bearer credential: keep it out of logs even on accident.
# (Skipped in DRY_RUN, where stdout must stay a clean JSON payload for tests.)
[ "${DRY_RUN:-}" = 1 ] || echo "::add-mask::${WECOM_WEBHOOK_URL}"

# --- conclusion --------------------------------------------------------------
# Precedence: explicit input > needs_json (mode 2) > job.status (mode 1).
status="${INPUT_STATUS:-}"
if [ -z "$status" ] && [ -n "${NEEDS_JSON:-}" ]; then
  status=$(jq -r 'if any(.[]; .result == "failure") then "failure"
                   elif any(.[]; .result == "cancelled") then "cancelled"
                   else "success" end' <<<"${NEEDS_JSON:-}" 2>/dev/null) \
    || note "invalid needs_json"
fi
[ -n "$status" ] || status="${JOB_STATUS:-failure}"
case "$status" in success|failure|cancelled) ;; *) note "unknown status '$status'" ;; esac

# --- failed / cancelled job names (mode 2 only) ------------------------------
failed_jobs=""
if [ -n "${NEEDS_JSON:-}" ] && [ "$status" != "success" ]; then
  failed_jobs=$(jq -r 'to_entries[]
      | select(.value.result == "failure" or .value.result == "cancelled")
      | .key' <<<"${NEEDS_JSON:-}" 2>/dev/null | sed 's/.*/`&`/' | paste -sd '、' -) || failed_jobs=""
fi

# --- message parts -----------------------------------------------------------
title="${INPUT_TITLE:-${GITHUB_WORKFLOW:-GitHub Actions}}"
repo="${GITHUB_REPOSITORY:-unknown/unknown}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-}"

actor="${GITHUB_TRIGGERING_ACTOR:-${GITHUB_ACTOR:-}}"
if [ "${GITHUB_EVENT_NAME:-}" = "schedule" ]; then
  trigger="定时任务"
else
  trigger="${GITHUB_EVENT_NAME:-unknown}${actor:+ by $actor}"
fi

case "$status" in
  success)   head='<font color="info">✅ '"$title"' 成功</font>' ;;
  failure)   head='<font color="warning">❌ '"$title"' 失败</font>' ;;
  cancelled) head='<font color="comment">⚪ '"$title"' 已取消</font>' ;;
esac

content="$head
> 仓库:[$repo](${GITHUB_SERVER_URL:-https://github.com}/$repo)
> 分支:${GITHUB_REF_NAME:-unknown}　触发:$trigger"

# Duration since run_started_at; skipped silently if the timestamp is unusable.
if [ -n "${GITHUB_RUN_STARTED_AT:-}" ] \
    && start=$(date -u -d "$GITHUB_RUN_STARTED_AT" +%s 2>/dev/null); then
  secs=$(( $(date -u +%s) - start ))
  [ "$secs" -lt 0 ] && secs=0
  content+="
> 耗时:$(printf '%dm %02ds' $((secs / 60)) $((secs % 60)))"
fi

if [ -n "$failed_jobs" ]; then
  content+="
> 失败任务:$failed_jobs"
fi

if [ -n "${EXTRA_INFO:-}" ]; then
  content+="
${EXTRA_INFO:-}"
fi

content+="
[查看运行详情]($run_url)"

# WeCom caps markdown content at 4096 bytes. Drop the optional parts first,
# then hard-truncate; the run link is the one line that must survive.
if [ "$(wc -c <<<"$content")" -gt 4096 ]; then
  if [ -n "${EXTRA_INFO:-}" ]; then
    content=${content//$'\n'"${EXTRA_INFO:-}"/}
  fi
  if [ "$(wc -c <<<"$content")" -gt 4096 ] && [ -n "$failed_jobs" ]; then
    content=${content//$'\n'> 失败任务:\`$failed_jobs\`/}
  fi
  if [ "$(wc -c <<<"$content")" -gt 4096 ]; then
    content=$(printf '%s' "$content" | head -c 4090)'…'
  fi
fi

payload=$(jq -n --arg c "$content" '{msgtype:"markdown",markdown:{content:$c}}')

if [ "${DRY_RUN:-}" = 1 ]; then
  printf '%s\n' "$payload"
  exit 0
fi

resp=$(mktemp)
trap 'rm -f "$resp"' EXIT
code=$(curl -sS --max-time 10 --retry 2 --retry-delay 3 -o "$resp" -w '%{http_code}' \
  -H 'Content-Type: application/json' -d "$payload" "$WECOM_WEBHOOK_URL" 2>/dev/null) \
  || { note "send failed (network error)"; }
# WeCom answers 200 with errcode != 0 on rate limits and keyword mismatches,
# so the body must be checked too.
if [ "$code" != "200" ] || ! jq -e '.errcode == 0' "$resp" >/dev/null 2>&1; then
  note "send failed (http=$code): $(head -c 200 "$resp")"
fi
