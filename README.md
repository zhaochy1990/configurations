# configurations

Shared GitHub Actions config.

## `calver-release`

Per-package CalVer release for monorepos where every package versions
independently. One push that touches several packages produces **one** commit
covering all of them:

```
chore: bump version [skip ci]

bump api to version 2026.9.5
bump web to version 2026.9.3
```

### State

A single root **`versions.json`**:

```json
{ "api": "2026.9.4", "web": "2026.9.2" }
```

That is the only record. There are **no git tags** and **no commit-message
markers**. A package with no entry has never been released.

### How "what changed" is decided

By **this push's diff** — never by "everything since the last release". That
removes the class of bugs where a shared boundary makes one package swallow
another's commits: every push evaluates every package, and a package touched by
the push is released in that same run, so there is no unreleased window to lose
track of. `versions.json` is pure state and never doubles as a boundary.

Two ways to supply the diff:

| how | notes |
|---|---|
| `mode: plan` | generates `dorny/paths-filter` filters from the manifest and asks GitHub which paths changed. Works on a shallow checkout. |
| `--base <sha>` | plain `git diff --name-only <sha> HEAD`. Needs that commit to be present locally. |

### Two phases

```
plan  → detect changed packages, compute next versions   (writes nothing)
build → build/push artifacts tagged with those versions
bump  → rewrite versions.json + ONE commit + push + dispatch
```

`bump` must run **last**: if a build fails, `versions.json` must not advance, or
a downstream deploy would point at an artifact that was never published.

### Inputs

| input | default | notes |
|---|---|---|
| `mode` | `plan` | `plan` or `bump` |
| `manifest` | `.github/release-packages.json` | see below |
| `versions` | `versions.json` | the only state |
| `changed` | — | comma list; required in `bump` mode. Pass the matching plan step's `changed` output so both phases agree. |
| `base-branch` | `master` | branch the bump commit is pushed to |
| `deploy-workflow` | — | workflow file to dispatch once after publishing, with a `packages` input holding the plan JSON |

Outputs: `changed`, `packages` (JSON array of `{name, version, previous}`),
`message`, `released`.

### Manifest

```json
{
  "packages": [
    { "name": "api", "paths": ["svc/api/**", "libs/shared/**"] },
    { "name": "web", "paths": ["apps/web/**"] }
  ]
}
```

| field | required | meaning |
|---|---|---|
| `name` | yes | key in `versions.json`, and the subject of the bump line. Must be unique. |
| `paths` | yes | globs used to build the paths-filter. The script strips a trailing `/**` and prefix-matches, so `svc/api` matches `svc/api/x.go` but not `svc/api-extra/x.go`. |

Do **not** add `on.push.paths` to the release workflow. Path gating lives in the
manifest: a workflow that only fires for a subset of paths can never see a push
that touched two packages, which is exactly what forces two separate release
workflows to race on the same branch.

### Version scheme

`YYYY.M.MICRO` per package. Same year+month as that package's previous version →
`MICRO + 1`. New month → `MICRO = 1`. Never released → `1`.

### Known limits

- **Shared paths are duplicated, not derived.** A directory several packages
  depend on must be listed in each one's `paths`. A `dependsOn` field could
  derive it.
- `versions.json` is written by the bot, so branch protection must allow it.
- Packages built from the same source must all list that path. They then bump in
  lockstep by construction.

## Development

```sh
bash tests/run.sh
```

26 fixture-based checks: version math, month rollover, `versions.json` as the
only state, independent per-package counters, `--base` diff detection, prefix
matching, unrelated changes releasing nothing, and the real commit output.
