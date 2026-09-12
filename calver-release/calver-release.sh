#!/usr/bin/env bash
#
# calver-release.sh — per-package CalVer release for a monorepo.
#
# Phases:
#   bump-versions    --changed a,b | --base <sha>
#       Work out the next version of every package this push touched and print
#       the plan. Writes nothing, commits nothing — it only produces the version
#       numbers that the build step will tag artifacts with.
#
#   commit-versions  --set <plan json> [--push]
#       Write those versions into the versions file and commit them. Meant to run
#       only once the artifacts have been built AND pushed, so the recorded
#       version always names something that exists. With --push it also pushes
#       the branch and dispatches the deploy workflow.
#
# State lives in a single root versions file (default versions.json). There are
# no git tags and no commit-message markers.
#
# Environment:
#   CALVER_NOW=YYYY-MM-DD   override "today" (used by tests)
#   INPUT_BASE_BRANCH       branch to push to (default: current branch)
#   INPUT_DEPLOY_WORKFLOW   workflow file to dispatch once after publishing
#   GITHUB_OUTPUT           if set, outputs are written there too
#
set -euo pipefail

MANIFEST=".github/release-packages.json"
VERSIONS="versions.json"
CHANGED=""
CHANGED_MODE=""
BASE=""
SET=""
PHASE=""
PUSH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="${2:?--manifest needs a value}"; shift 2 ;;
    --versions) VERSIONS="${2:?--versions needs a value}"; shift 2 ;;
    --changed)  CHANGED="${2?--changed needs a value}"; CHANGED_MODE=list; shift 2 ;;
    --base)     BASE="${2?--base needs a value}"; CHANGED_MODE=base; shift 2 ;;
    --set)      SET="${2?--set needs a value}"; shift 2 ;;
    --phase)    PHASE="${2:?--phase needs a value}"; shift 2 ;;
    --push)     PUSH=1; shift ;;
    -h|--help)  sed -n '3,20p' "$0"; exit 0 ;;
    *) echo "calver-release: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "calver-release: jq is required" >&2; exit 1; }
case "$PHASE" in
  bump-versions)
    if [ -n "$SET" ]; then
      echo "calver-release: --set belongs to --phase commit-versions" >&2
      exit 2
    fi
    if [ -z "$CHANGED_MODE" ]; then
      echo "calver-release: --phase bump-versions needs --changed a,b or --base <sha>" >&2
      exit 2
    fi
    ;;
  commit-versions)
    if [ -n "$CHANGED_MODE" ]; then
      echo "calver-release: --changed/--base belong to --phase bump-versions" >&2
      exit 2
    fi
    if [ -z "$SET" ]; then
      echo "calver-release: --phase commit-versions needs --set <plan json>" >&2
      exit 2
    fi
    ;;
  '')
    echo "calver-release: --phase bump-versions | commit-versions is required" >&2
    exit 2
    ;;
  *)
    echo "calver-release: unknown phase: $PHASE" >&2
    exit 2
    ;;
esac

[ -f "$MANIFEST" ] || { echo "calver-release: no manifest at $MANIFEST" >&2; exit 1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

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

manifest_names() { jq -r '.packages[].name' "$MANIFEST"; }

# ---------------------------------------------------------------------------
# Resolve the release set.
#
#   bump-versions   detect what this push touched, then compute the next version
#                   by reading the versions file.
#   commit-versions persist the plan that was already built and shipped.
#                   Deliberately does NOT recompute — if another push lands
#                   while this build runs, recomputing here would record a
#                   version that nothing was ever built for.
# ---------------------------------------------------------------------------
if [ "$PHASE" = commit-versions ]; then
  PACKAGES=$(printf '%s' "$SET" | jq -c '.')
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if ! manifest_names | grep -qxF "$n"; then
      echo "calver-release: --set names an unknown package: $n" >&2
      exit 1
    fi
  done < <(printf '%s' "$PACKAGES" | jq -r '.[].name')
else
  if [ "$CHANGED_MODE" = list ]; then
    CHANGED_LIST=$(printf '%s' "$CHANGED" | tr ',' ' ')
  else
    CHANGED_LIST=""
    DIFF_FILES=$(git diff --name-only "$BASE" HEAD)
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

  is_changed() {
    local n
    for n in $CHANGED_LIST; do [ "$n" = "$1" ] && return 0; done
    return 1
  }

  ROWS="$TMPD/rows.jsonl"
  : > "$ROWS"
  pkg_count=$(jq '.packages | length' "$MANIFEST")
  i=0
  while [ "$i" -lt "$pkg_count" ]; do
    name=$(jq -r ".packages[$i].name // empty" "$MANIFEST")
    [ -n "$name" ] || { echo "calver-release: packages[$i].name is missing" >&2; exit 1; }
    i=$((i + 1))
    is_changed "$name" || continue
    if [ -f "$VERSIONS" ]; then
      previous=$(jq -r --arg n "$name" '.[$n] // empty' "$VERSIONS")
    else
      previous=""
    fi
    version=$(next_version "$previous")
    jq -nc --arg name "$name" --arg version "$version" --arg previous "$previous" \
      '{name:$name, version:$version, previous:$previous}' >> "$ROWS"
  done
  PACKAGES=$(jq -s '.' "$ROWS")
fi

# ---------------------------------------------------------------------------
# Apply the release set to the versions file.
# ---------------------------------------------------------------------------
NEWVERSIONS="$TMPD/versions.json"
if [ -f "$VERSIONS" ]; then cp "$VERSIONS" "$NEWVERSIONS"; else printf '{}\n' > "$NEWVERSIONS"; fi
while IFS=$'\t' read -r n v; do
  [ -n "$n" ] || continue
  jq --arg n "$n" --arg v "$v" '.[$n] = $v' "$NEWVERSIONS" > "$NEWVERSIONS.next"
  mv "$NEWVERSIONS.next" "$NEWVERSIONS"
done < <(printf '%s' "$PACKAGES" | jq -r '.[] | [.name, .version] | @tsv')

BUMP=()
while IFS= read -r line; do
  [ -n "$line" ] && BUMP[${#BUMP[@]}]="$line"
done < <(printf '%s' "$PACKAGES" | jq -r '.[] | "bump \(.name) to version \(.version)"')
COUNT=${#BUMP[@]}

SUBJECT="chore: bump version [skip ci]"
BODY=""
[ "$COUNT" -gt 0 ] && BODY=$(printf '%s\n' "${BUMP[@]}")
MESSAGE="$SUBJECT"
[ -n "$BODY" ] && MESSAGE="$SUBJECT

$BODY"

PLAN=$(jq -n --argjson packages "$PACKAGES" --arg message "$MESSAGE" \
  '{released: (($packages | length) > 0), message: $message, packages: $packages}')

# ---------------------------------------------------------------------------
# commit-versions: rewrite the versions file, then one commit covering every
# package. Nothing above this line has touched the working tree.
# ---------------------------------------------------------------------------
if [ "$PHASE" = commit-versions ] && [ "$COUNT" -gt 0 ]; then
  cp "$NEWVERSIONS" "$VERSIONS"

  git config user.name 'github-actions[bot]'
  git config user.email 'github-actions[bot]@users.noreply.github.com'
  git add -- "$VERSIONS"
  # Two -m flags so git keeps the blank line between subject and body.
  git commit -q -m "$SUBJECT" -m "$BODY"
fi

# ---------------------------------------------------------------------------
# --push: one push, then hand the plan to the deploy workflow.
# ---------------------------------------------------------------------------
if [ "$PUSH" -eq 1 ] && [ "$COUNT" -gt 0 ]; then
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
