#!/usr/bin/env bash
# Fixture-based checks for notify-wecom.sh. Run: bash tests/run.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/notify-wecom/notify-wecom.sh"
PASS=0
FAIL=0

# run — invoke the script in DRY_RUN mode with a default success shape; extra
# VAR=value args are appended last so callers can override any default.
run() {
  env \
    WECOM_WEBHOOK_URL="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=test" \
    GITHUB_EVENT_NAME=push \
    GITHUB_TRIGGERING_ACTOR=zoe \
    GITHUB_WORKFLOW=Release \
    GITHUB_REPOSITORY=acme/stride \
    GITHUB_REF_NAME=master \
    GITHUB_RUN_ID=42 \
    GITHUB_SERVER_URL=https://github.com \
    JOB_STATUS=success \
    DRY_RUN=1 \
    "$@" \
    bash "$SCRIPT"
}

content_of() { jq -r '.markdown.content' ; }

expect() { # expect <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1"
    echo "  actual:   $(printf '%q' "$2")"
    echo "  expected: $(printf '%q' "$3")"
  fi
}

expect_contains() { # expect_contains <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1 — expected to contain $(printf '%q' "$3")"
    echo "  actual: $(printf '%q' "$2")"
  fi
}

# mode 1: job.status=success → green message with trigger and run link
out=$(run | content_of)
expect_contains "success icon" "$out" '✅ Release 成功'
expect_contains "repo link" "$out" '[acme/stride](https://github.com/acme/stride)'
expect_contains "branch + trigger" "$out" '分支:master　触发:push by zoe'
expect_contains "run link" "$out" 'https://github.com/acme/stride/actions/runs/42'
expect "no failed line on success" "$(grep -c '失败任务' <<<"$out")" "0"

# mode 1: job.status=failure → warning colour, no failed-jobs line (none known)
out=$(run JOB_STATUS=failure | content_of)
expect_contains "failure icon" "$out" '❌ Release 失败'
expect_contains "failure colour" "$out" '<font color="warning">'
expect "no failed line in mode 1" "$(grep -c '失败任务' <<<"$out")" "0"

# mode 2: needs_json with one failure and one cancel → both listed, skipped ignored
needs='{"build":{"result":"success"},"test":{"result":"failure"},"lint":{"result":"skipped"},"docker":{"result":"cancelled"}}'
out=$(run NEEDS_JSON="$needs" | content_of)
expect_contains "derived failure" "$out" '❌ Release 失败'
expect_contains "failed jobs listed" "$out" '失败任务:`test`、`docker`'

# mode 2: all success → green, no failed line
needs='{"build":{"result":"success"},"test":{"result":"success"}}'
out=$(run NEEDS_JSON="$needs" | content_of)
expect_contains "derived success" "$out" '✅ Release 成功'
expect "no failed line" "$(grep -c '失败任务' <<<"$out")" "0"

# mode 2: all skipped counts as success (nothing ran)
needs='{"lint":{"result":"skipped"},"docker":{"result":"skipped"}}'
out=$(run NEEDS_JSON="$needs" | content_of)
expect_contains "skipped-only run" "$out" '✅ Release 成功'

# explicit status input overrides everything
out=$(run NEEDS_JSON='{"build":{"result":"success"}}' INPUT_STATUS=cancelled | content_of)
expect_contains "status override" "$out" '⚪ Release 已取消'

# schedule runs show 定时任务, not an actor
out=$(run GITHUB_EVENT_NAME=schedule GITHUB_ACTOR=github-actions[bot] | content_of)
expect_contains "schedule trigger" "$out" '触发:定时任务'

# triggering_actor wins over the bot actor
out=$(run GITHUB_TRIGGERING_ACTOR=zoe GITHUB_ACTOR=github-actions[bot] | content_of)
expect_contains "triggering actor wins" "$out" 'push by zoe'

# extra_info is inserted before the run link
out=$(run EXTRA_INFO='> 镜像无变更，未开部署 PR' | content_of)
expect_contains "extra_info present" "$out" '> 镜像无变更，未开部署 PR'
link_after_extra=$(sed -n '/镜像无变更/,$p' <<<"$out" | grep -c '查看运行详情')
expect "run link after extra_info" "$link_after_extra" "1"

# missing webhook → warning + exit 0, no output payload
out=$(WECOM_WEBHOOK_URL= DRY_RUN=1 bash "$SCRIPT" 2>&1) && rc=0 || rc=$?
expect "missing webhook exits 0" "$rc" "0"
expect_contains "missing webhook warns" "$out" 'WECOM_WEBHOOK_URL is not set'
expect "missing webhook sends nothing" "$(grep -c 'msgtype' <<<"$out")" "0"

# bogus needs_json → warning + exit 0
out=$(run NEEDS_JSON='not json' 2>&1) && rc=0 || rc=$?
expect "bad needs_json exits 0" "$rc" "0"
expect_contains "bad needs_json warns" "$out" 'invalid needs_json'

# 4096-byte cap: extra_info and failed list get dropped, run link survives
long_extra=$(printf '> %0.sx' $(seq 1 4500))
needs='{"a_very_long_job_name":{"result":"failure"}}'
out=$(run NEEDS_JSON="$needs" EXTRA_INFO="$long_extra" | content_of)
expect "content within 4096 bytes" "$([ ${#out} -le 4096 ] && echo yes)" "yes"
expect_contains "run link survives cap" "$out" '查看运行详情'
expect "long extra dropped" "$(grep -c 'xxxx' <<<"$out")" "0"

echo "notify-wecom: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
