# configurations

Shared GitHub Actions config.

## `calver-release`

Per-package CalVer release for monorepos where every package versions
independently. Releases happen in **three phases**, and the order is the point:
a version is only written down once something with that version actually exists.

```
1. bump-versions    work out the next version of every package this push touched
2. build            build and push artifacts tagged with those versions
3. commit-versions  commit the versions to the repository
```

### 1. `bump-versions`

Detects which packages this push touched and calculates each one's next version.

**This phase only updates version numbers. It writes nothing and commits
nothing** — the working tree is left untouched. Its output is the list of
`{name, version}` pairs that phase 2 will build with.

### 2. `build` (your own jobs)

Build the images and **push them to the registry, tagged with the versions from
phase 1**. Feed phase 1's `packages` output into a matrix so every affected
package is built with the version it was assigned.

### 3. `commit-versions`

Once every image is built **and pushed**, this phase writes the new versions into
the versions file and commits them — one commit covering every package:

```
chore: bump version [skip ci]

bump api to version 2026.9.5
bump web to version 2026.9.3
```

It is handed phase 1's plan and **never recalculates**. If another push lands
while your build is running, the versions file has already moved on; recalculating
here would record a version that nothing was ever built for.

### Setup

**1.** Add a manifest at `.github/release-packages.json`:

```json
{
  "packages": [
    { "name": "api", "paths": ["svc/api/**", "libs/shared/**"] },
    { "name": "web", "paths": ["apps/web/**"] }
  ]
}
```

**2.** Add a state file at `versions.json`. It may be empty to start — a package
with no entry is treated as never released:

```json
{}
```

**3.** Add the workflow:

```yaml
name: Release

on:
  push:
    branches: [master]

permissions:
  contents: write # the commit-versions commit
  actions: write # dispatch the deploy workflow

jobs:
  bump-versions:
    runs-on: ubuntu-latest
    outputs:
      changed: ${{ steps.bump.outputs.changed }}
      packages: ${{ steps.bump.outputs.packages }}
    steps:
      - uses: actions/checkout@v4
      - id: bump
        uses: zhaochy1990/configurations/calver-release@v1
        with:
          phase: bump-versions

  build:
    needs: bump-versions
    if: needs.bump-versions.outputs.changed != ''
    runs-on: ubuntu-latest
    strategy:
      matrix:
        package: ${{ fromJSON(needs.bump-versions.outputs.packages) }}
    steps:
      - run: echo "build and push ${{ matrix.package.name }}:${{ matrix.package.version }}"

  commit-versions:
    needs: [bump-versions, build]
    if: needs.bump-versions.outputs.changed != ''
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: zhaochy1990/configurations/calver-release@v1
        with:
          phase: commit-versions
          packages: ${{ needs.bump-versions.outputs.packages }}
          deploy-workflow: deploy.yml
```

Do not add `on.push.paths` to this workflow — path gating comes from the
manifest, and a workflow that only fires for some paths cannot see a push that
touched more than one package.

### Inputs

| input | default | notes |
|---|---|---|
| `phase` | `bump-versions` | `bump-versions` or `commit-versions` |
| `manifest` | `.github/release-packages.json` | |
| `versions` | `versions.json` | the only state |
| `packages` | — | the plan JSON; required in `commit-versions`. Pass the `bump-versions` step's `packages` output. |
| `base` | — | ref to diff against for change detection, e.g. `github.event.before`. Empty means `dorny/paths-filter` decides from the event. Using it needs a checkout deep enough to reach the ref. |
| `base-branch` | `master` | branch `commit-versions` pushes to |
| `deploy-workflow` | — | workflow file to dispatch once after committing, with a `packages` input holding the plan JSON |

### Outputs

| output | phase | notes |
|---|---|---|
| `changed` | `bump-versions` | comma-separated names of packages this push touched |
| `packages` | both | JSON array of `{ "name", "version", "previous" }` |
| `message` | both | the commit message, subject and body |
| `released` | both | `"true"` when at least one package is in the plan |

### Manifest fields

| field | required | meaning |
|---|---|---|
| `name` | yes | key in `versions.json` and subject of the bump line. Must be unique. |
| `paths` | yes | globs deciding which files belong to the package. `svc/api` matches `svc/api/x.go` but not `svc/api-extra/x.go`. |

### Version scheme

`YYYY.M.MICRO` per package. Same year and month as that package's previous
version → `MICRO + 1`. New month → `MICRO = 1`. Never released → `1`.

### Notes

- A directory shared by several packages must be listed in each package's
  `paths`. There is no `dependsOn`.
- `versions.json` is committed by the Action, so branch protection must allow it.
- Packages built from the same sources must all list those sources. They then
  bump together.
- `commit-versions` must be the last job: it advances `versions.json`, which
  downstream consumers read.

## `notify-wecom`

Posts the outcome of a GitHub Actions run to a WeCom Work (企业微信) group robot
as one markdown message: result icon, workflow name, repo/branch, trigger,
duration and a clickable link to the run. On failure it lists the failed (or
cancelled) jobs.

The action **never fails the calling pipeline** — a missing webhook or a failed
send only emits a `::warning::`. A notification is a side channel; it must not
turn a green run red.

Two usage modes, chosen by job count:

**Single-job workflow** — last step of the job, with `if: always()`. The action
reads `job.status`:

```yaml
      - name: Notify WeCom
        if: always()
        uses: zhaochy1990/configurations/notify-wecom@v1
        with:
          webhook_url: ${{ secrets.WECOM_WEBHOOK_URL }}
```

**Multi-job workflow** — a final `notify` job that needs every real job, with
`if: always()`. Pass `toJSON(needs)` so the action can derive the overall
conclusion (failure > cancelled > success; skipped jobs are ignored) and list
failed job ids:

```yaml
  notify:
    needs: [build, test, publish]
    if: always()
    runs-on: ubuntu-latest
    timeout-minutes: 2
    permissions: {}
    steps:
      - uses: zhaochy1990/configurations/notify-wecom@v1
        with:
          webhook_url: ${{ secrets.WECOM_WEBHOOK_URL }}
          needs_json: ${{ toJSON(needs) }}
```

### Setup

**1.** Create a group robot in the target WeCom group (群设置 → 群机器人 → 添加)
and copy its webhook URL.

**2.** Store it as the `WECOM_WEBHOOK_URL` repository secret.

### Inputs

| input | default | notes |
|---|---|---|
| `webhook_url` | — | the robot webhook; empty → warning + skip, exit 0 |
| `needs_json` | — | `toJSON(needs)` from a final notify job (multi-job mode) |
| `status` | — | explicit override: `success` / `failure` / `cancelled` |
| `extra_info` | — | extra markdown line(s) before the run link |
| `title` | `github.workflow` | display name of the workflow |

### Notes

- Schedule-triggered runs show 定时任务 instead of an actor; `github.triggering_actor`
  is preferred over `github.actor`, so token-dispatched runs name the real
  triggerer.
- Content is capped at WeCom's 4096-byte limit; the run link is the line that
  always survives.
- A cancelled run may send nothing if its notify job never started — `always()`
  cannot wake a job that was never launched. Treat cancellation notices as
  best-effort.

## Development

```sh
bash tests/run.sh
```

41 fixture-based checks for calver-release covering the version math, the state
file, both change detection paths, phase/flag validation, and the emitted
commit; 26 checks for notify-wecom covering both usage modes, status
derivation, the trigger line, the byte cap and the never-fail guarantee.
