#!/usr/bin/env bash
#
# calver-release.sh — per-package CalVer release for a monorepo.
#
# Modes:
#   (default)   print the release plan as JSON, touch nothing
#   --apply     also rewrite the versions file and create ONE bump commit
#   --publish   --apply, then push and dispatch the deploy workflow
#
# State lives in a single root versions file (default versions.json). There are
# no git tags and no commit-message markers: "which packages changed" is decided
# from one push's diff, so no history scan is needed and a package can never be
# skipped by a stale boundary.
#
# Environment:
#   CALVER_NOW=YYYY-MM-DD   override "today" (used by tests)
#   INPUT_BASE_BRANCH       branch to push to (default: current branch)
#   INPUT_DEPLOY_WORKFLOW   workflow file to dispatch once after publishing
#   GITHUB_OUTPUT           if set, plan/released are written there too
#
set -euo pipefail

MANIFEST=".github/release-packages.json"
VERSIONS="versions.json"
CHANGED=""
CHANGED_MODE=""
BASE=""
MODE=plan
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:?--manifest needs a value}"; shift 2 ;;
    --versions) VERSIONS="${2:?--versions needs a value}"; shift 2 ;;
    --changed)  CHANGED="${2?--changed needs a value}"; CHANGED_MODE=list; shift 2 ;;
    --base)     BASE="${2?--base needs a value}"; CHANGED_MODE=base; shift 2 ;;
    --apply)    MODE=apply; shift ;;
    --publish)  MODE=publish; shift ;;
    -h|--help)  sed -n '3,18p' "$0"; exit 0 ;;
    *) echo "calver-release: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "calver-release: jq is required" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "calver-release: no manifest at $MANIFEST" >&2; exit 1; }
if [ -z "$CHANGED_MODE" ]; then
  echo "calver-release: pass --changed a,b or --base <sha> to say what changed" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Clock. CalVer is YYYY.M.MICRO with MICRO resetting to 1 in a new month.
# ---------------------------------------------------------------------------
NOW="${CALVER_NOW:-$(date -u +%Y-%m-%d)}"
YEAR="${NOW%%-*}"
MONTH="$((10#$(printf '%s' "$NOW" | cut -d- -f2)))"

next_version() {  # next_version <previous-version-or-empty>  -> X.Y.Z
  local v="$1" ty tm micro
  if [ -z "$v" ]; then printf '%s.%s.1\n' "$YEAR" "$MONTH"; return; fi
  ty="${v%%.*}"
  tm="$((10#$(printf '%s' "$v" | cut -d. -f2)))"
  micro="$((10#$(printf '%s' "$v" | cut -d. -f3)))"
  if [ "$ty" = "$YEAR" ] && [ "$tm" = "$MONTH" ]; then
    printf '%s.%s.%s\n' "$YEAR" "$MONTH" "$((micro + 1))"
  else
    printf '%s.%s.1\n' "$YEAR" "$MONTH"
  fi
}

# A manifest path is a directory prefix; `svc/api` also matches `svc/api/**`.
matches_path() {  # matches_path <file> <prefix>
  local p="${2%/\*\*}"; p="${p%/\*}"
  [ "$1" = "$p" ] && return 0
  case "$1" in "$p"/*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# Which packages changed: from an explicit list, or from the push diff.
# ---------------------------------------------------------------------------
if [ "$CHANGED_MODE" = list ]; then
  CHANGED_LIST=$(printf '%s' "$CHANGED" | tr ',' ' ')
else
  DIFF_FILES=$(git diff --name-only "$BASE" HEAD)
  CHANGED_LIST=""
  n_pkgs=$(jq '.packages | length' "$MANIFEST")
  k=0
  while [ "$k" -lt "$n_pkgs" ]; do
    nm=$(jq -r ".packages[$k].name" "$MANIFEST")
    hit=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      while IFS= read -r pfx; do
        [ -n "$pfx" ] || continue
        if matches_path "$f" "$pfx"; then hit=1; break; fi
      done < <(jq -r ".packages[$k].paths[]?" "$MANIFEST")
      [ "$hit" -eq 1 ] && break
    done <<<"$DIFF_FILES"
    [ "$hit" -eq 1 ] && CHANGED_LIST="$CHANGED_LIST $nm"
    k=$((k + 1))
  done
fi

is_changed() {  # is_changed <name>
  local n
  for n in $CHANGED_LIST; do [ "$n" = "$1" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Plan: next version for every changed package, read from the versions file.
# ---------------------------------------------------------------------------
ROWS=$(mktemp)
NEWVERSIONS=$(mktemp)
trap 'rm -f "$ROWS" "$NEWVERSIONS"' EXIT
: > "$ROWS"
if [ -f "$VERSIONS" ]; then cp "$VERSIONS" "$NEWVERSIONS"; else printf '{}\n' > "$NEWVERSIONS"; fi

BUMP=()
pkg_count=$(jq '.packages | length' "$MANIFEST")
i=0
while [ "$i" -lt "$pkg_count" ]; do
  name=$(jq -r ".packages[$i].name // empty" "$MANIFEST")
  [ -n "$name" ] || { echo "calver-release: packages[$i].name is missing" >&2; exit 1; }
  i=$((i + 1))
  is_changed "$name" || continue

  previous=$(jq -r --arg n "$name" '.[$n] // empty' "$NEWVERSIONS")
  version=$(next_version "$previous")

  jq -nc --arg name "$name" --arg version "$version" --arg previous "$previous" \
    '{name:$name, version:$version, previous:$previous}' >> "$ROWS"

  BUMP[${#BUMP[@]}]="bump $name to version $version"
  jq --arg n "$name" --arg v "$version" '.[$n] = $v' "$NEWVERSIONS" > "$NEWVERSIONS.next"
  mv "$NEWVERSIONS.next" "$NEWVERSIONS"
done

PACKAGES=$(jq -s '.' "$ROWS")
COUNT=${#BUMP[@]}

SUBJECT="chore: bump version [skip ci]"
BODY=""
if [ "$COUNT" -gt 0 ]; then
  BODY=$(printf '%s\n' "${BUMP[@]}")
fi
MESSAGE="$SUBJECT"
[ -n "$BODY" ] && MESSAGE="$SUBJECT

$BODY"

PLAN=$(jq -n --argjson packages "$PACKAGES" --arg message "$MESSAGE" \
  '{released: (($packages | length) > 0), message: $message, packages: $packages}')

# ---------------------------------------------------------------------------
# Apply: rewrite the versions file, then one commit covering every package.
# ---------------------------------------------------------------------------
if [ "$MODE" != plan ] && [ "$COUNT" -gt 0 ]; then
  cp "$NEWVERSIONS" "$VERSIONS"

  git config user.name 'github-actions[bot]'
  git config user.email 'github-actions[bot]@users.noreply.github.com'
  git add -- "$VERSIONS"
  # Two -m flags so git keeps the blank line between subject and body.
  git commit -q -m "$SUBJECT" -m "$BODY"
fi

# ---------------------------------------------------------------------------
# Publish: one push, then hand the plan to the deploy workflow.
# ---------------------------------------------------------------------------
if [ "$MODE" = publish ] && [ "$COUNT" -gt 0 ]; then
  BRANCH="${INPUT_BASE_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
  git push origin "$BRANCH" >&2

  if [ -n "${INPUT_DEPLOY_WORKFLOW:-}" ]; then
    gh workflow run "$INPUT_DEPLOY_WORKFLOW" --ref "$BRANCH" \
      -f packages="$(printf '%s' "$PACKAGES" | jq -c '.')" >&2
  fi
fi

printf '%s\n' "$PLAN"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "plan=$(printf '%s' "$PLAN" | jq -c '.')"
    echo "released=$(printf '%s' "$PLAN" | jq -r '.released')"
    echo "packages=$(printf '%s' "$PACKAGES" | jq -c '.')"
    echo "message=$(printf '%s' "$MESSAGE" | jq -Rs '.')"
  } >> "$GITHUB_OUTPUT"
fi
