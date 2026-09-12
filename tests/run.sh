#!/usr/bin/env bash
# Fixture-based checks for calver-release.sh. Run: bash tests/run.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/calver-release/calver-release.sh"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
PASS=0
FAIL=0

# fixture <name> — fresh repo with a two-package manifest, no versions file yet
fixture() {
  cd "$ROOT" && rm -rf "$1" && mkdir -p "$1/.github" && cd "$1"
  git init -q -b master 2>/dev/null || { git init -q; git symbolic-ref HEAD refs/heads/master; }
  git config user.email t@example.com
  git config user.name t
  git config commit.gpgsign false
  cat > .github/release-packages.json <<'JSON'
{"packages":[
  {"name":"pkg-a","paths":["a"]},
  {"name":"pkg-b","paths":["b"]}
]}
JSON
  git add -A && git commit -q -m "chore: init"
}

c() { # c <path> <message>
  mkdir -p "${1%/*}" 2>/dev/null || true
  echo "$RANDOM" >> "$1"
  git add -A
  git commit -q -m "$2"
}

run() { # run [extra args...] — --changed defaults to both packages
  CALVER_NOW="${NOW:-2026-09-15}" bash "$SCRIPT" \
    --manifest .github/release-packages.json "${@:---changed pkg-a,pkg-b}"
}
plan()  { run "$@"; }
# establish versions the way bump does: persist a plan that was "built".
bump() { # bump '<json>' — the plan, exactly as it would have been built
  CALVER_NOW="${NOW:-2026-09-15}" bash "$SCRIPT" \
    --manifest .github/release-packages.json "$@" --apply >/dev/null
}
# helper: apply a plan derived from the current changed set
apply() { # apply <names> [plan-date]
  local names="$1" json
  json=$(run --changed "$names" | jq -c '.packages')
  bump --set "$json"
}

expect() { # expect <label> <actual> <expected>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1"
    echo "  expected: $(printf '%q' "$3")"
    echo "  actual:   $(printf '%q' "$2")"
  fi
}

# --- 1. no versions file -> first release is .1 ---------------------------
fixture t1
P=$(plan --changed pkg-a)
expect "t1 released" "$(printf '%s' "$P" | jq -r '.released')"             "true"
expect "t1 version"  "$(printf '%s' "$P" | jq -r '.packages[0].version')"  "2026.9.1"
expect "t1 previous" "$(printf '%s' "$P" | jq -r '.packages[0].previous')" ""
expect "t1 plan writes nothing" "$([ -f versions.json ] && echo yes || echo no)" "no"

# --- 2. same month -> micro+1, read back from the versions file ------------
apply pkg-a
expect "t2 versions file" "$(jq -r '."pkg-a"' versions.json)" "2026.9.1"
expect "t2 micro++" "$(plan --changed pkg-a | jq -r '.packages[0].version')" "2026.9.2"

# --- 3. new month resets micro --------------------------------------------
apply pkg-a
NOW=2026-10-02
expect "t3 resets" "$(plan --changed pkg-a | jq -r '.packages[0].version')" "2026.10.1"
unset NOW

# --- 4. changed package stays at .1; untouched package is not in the plan --
fixture t4
apply pkg-a                     # pkg-a -> 2026.9.1
P=$(plan --changed pkg-b)
expect "t4 only b"      "$(printf '%s' "$P" | jq -r '.packages|length')" "1"
expect "t4 b version"   "$(printf '%s' "$P" | jq -r '.packages[0].version')" "2026.9.1"
expect "t4 a untouched" "$(jq -r '."pkg-a"' versions.json)" "2026.9.1"

# --- 5. two packages -> ONE commit listing both ---------------------------
fixture t5
expect "t5 message" "$(run --changed pkg-a,pkg-b | jq -r '.message')" \
  'chore: bump version [skip ci]

bump pkg-a to version 2026.9.1
bump pkg-b to version 2026.9.1'

# --- 6. nothing changed -> no release, no commit --------------------------
fixture t6
expect "t6 empty"     "$(run --changed '' | jq -r '.released')" "false"
run --changed '' --apply >/dev/null
expect "t6 no commit" "$(git rev-list --count HEAD)" "1"
expect "t6 released"  "$(run --changed pkg-a | jq -r '.released')" "true"

# --- 7. apply -> one commit, independent counters -------------------------
fixture t7
apply pkg-a,pkg-b                       # both -> 2026.9.1
apply pkg-a                             # only a -> 2026.9.2
expect "t7 subject" "$(git log -1 --pretty=%s)" "chore: bump version [skip ci]"
expect "t7 body"    "$(git log -1 --pretty=%b)" "bump pkg-a to version 2026.9.2"
expect "t7 counts"  "$(git rev-list --count HEAD)" "3"
expect "t7 state"   "$(jq -c . versions.json)" '{"pkg-a":"2026.9.2","pkg-b":"2026.9.1"}'
expect "t7 no tags" "$(git tag -l | wc -l | tr -d ' ')" "0"

# --- 8. --base derives changed packages from a real diff ------------------
fixture t8
BASE=$(git rev-parse HEAD)
mkdir -p a && echo x > a/f.txt          # only a/ touched
git add -A && git commit -q -m "feat(a): x"
expect "t8 diff only a" "$(run --base "$BASE" | jq -r '[.packages[].name]|join(",")')" "pkg-a"

mkdir -p b && echo y > b/f.txt          # now b/ too
git add -A && git commit -q -m "feat(b): y"
expect "t8 diff both" "$(run --base "$BASE" | jq -r '[.packages[].name]|join(",")')" "pkg-a,pkg-b"

# --- 9. unrelated change -> nothing released ------------------------------
mkdir -p docs && echo z > docs/d.md
git add -A && git commit -q -m "docs: x"
expect "t9 unrelated" "$(run --base "$(git rev-parse HEAD~1)" | jq -r '.released')" "false"

# --- 10. prefix path: svc/api must match svc/api/**, not svc/api-extra ---
fixture t10
jq '.packages[0].paths=["svc/api"]' .github/release-packages.json > m && mv m .github/release-packages.json
BASE=$(git rev-parse HEAD)
mkdir -p svc/api/internal && echo x > svc/api/internal/f.go
git add -A && git commit -q -m "feat(go): x"
expect "t10 prefix match" "$(run --base "$BASE" | jq -r '[.packages[].name]|join(",")')" "pkg-a"
# and a sibling dir that merely shares a name prefix must NOT match
mkdir -p svc/apilang && echo x > svc/apilang/f.go
git add -A && git commit -q -m "feat(lang): x"
expect "t10 no false prefix" "$(run --base "$(git rev-parse HEAD~1)" | jq -r '.released')" "false"

# --- 11. trailing /** in manifest paths still prefix-matches -------------
fixture t11
jq '.packages[0].paths=["svc/api/**"]' .github/release-packages.json > m && mv m .github/release-packages.json
BASE=$(git rev-parse HEAD)
mkdir -p svc/api/cmd && echo x > svc/api/cmd/main.go
git add -A && git commit -q -m "feat(go): x"
expect "t11 /** matches" "$(run --base "$BASE" | jq -r '[.packages[].name]|join(",")')" "pkg-a"

# --- 12. bump persists the plan it was given, never recomputes -------------
# Simulates another push landing while this build is in flight: the versions
# file has already moved to 2026.9.9, but the plan being bumped is the one that
# was actually built (2026.9.5). Recomputing here would write 2026.9.10.
fixture t12
printf '{"pkg-a":"2026.9.9"}\n' > versions.json
git add -A && git commit -q -m "chore: state moved on"
bump --set '[{"name":"pkg-a","version":"2026.9.5","previous":"2026.9.4"}]'
expect "t12 uses given version" "$(jq -r '."pkg-a"' versions.json)" "2026.9.5"
expect "t12 commit body"        "$(git log -1 --pretty=%b)" "bump pkg-a to version 2026.9.5"
expect "t12 keys unchanged"     "$(jq -r 'keys|join(",")' versions.json)" "pkg-a"

# --- 13. bump rejects a name that is not in the manifest ------------------
expect "t13 rejects unknown" \
  "$(bump --set '[{"name":"nope","version":"1.2.3"}]' 2>&1 | grep -c 'unknown package' || true)" "1"

# --- 14. plan and bump agree on the version -------------------------------
fixture t14
PLAN=$(run --changed pkg-a,pkg-b | jq -c '.packages')
bump --set "$PLAN"
expect "t14 a matches plan" "$(jq -r '."pkg-a"' versions.json)" "$(printf '%s' "$PLAN" | jq -r '.[0].version')"
expect "t14 b matches plan" "$(jq -r '."pkg-b"' versions.json)" "$(printf '%s' "$PLAN" | jq -r '.[1].version')"
expect "t14 no tags"        "$(git tag -l | wc -l | tr -d ' ')" "0"

# --- 15. message output is JSON-encoded for GITHUB_OUTPUT ----------------
fixture t15
expect "t15 message json" "$(run --changed pkg-a | jq -r '.message' | jq -Rs .)" '"chore: bump version [skip ci]\n\nbump pkg-a to version 2026.9.1\n"'

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
