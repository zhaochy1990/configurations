# configurations

Shared GitHub Actions config.

## `calver-release`

Per-package CalVer release for monorepos where every package versions
independently. Yields one commit per release covering every package that
changed:

```
chore: bump version [skip ci]

bump api to version 2026.9.5
bump web to version 2026.9.3
```

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

**3.** Add a workflow. Call the action twice: `plan` first to learn which
packages changed and what their next versions are, then `bump` last, after the
artifacts have built.

```yaml
name: Release

on:
  push:
    branches: [master]

permissions:
  contents: write # the bump commit
  actions: write # dispatch the deploy workflow

jobs:
  plan:
    runs-on: ubuntu-latest
    outputs:
      changed: ${{ steps.plan.outputs.changed }}
      packages: ${{ steps.plan.outputs.packages }}
    steps:
      - uses: actions/checkout@v4
      - id: plan
        uses: zhaochy1990/configurations/calver-release@v1
        with:
          mode: plan

  build:
    needs: plan
    if: needs.plan.outputs.changed != ''
    runs-on: ubuntu-latest
    strategy:
      matrix:
        package: ${{ fromJSON(needs.plan.outputs.packages) }}
    steps:
      - run: echo "build ${{ matrix.package.name }}:${{ matrix.package.version }}"

  bump:
    needs: [plan, build]
    if: needs.plan.outputs.changed != ''
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: zhaochy1990/configurations/calver-release@v1
        with:
          mode: bump
          changed: ${{ needs.plan.outputs.changed }}
          deploy-workflow: deploy.yml
```

Do not add `on.push.paths` to this workflow — path gating comes from the
manifest, and a workflow that only fires for some paths cannot see a push that
touched more than one package.

### Inputs

| input | default | notes |
|---|---|---|
| `mode` | `plan` | `plan` or `bump` |
| `manifest` | `.github/release-packages.json` | |
| `versions` | `versions.json` | the only state |
| `changed` | — | comma-separated names; required in `bump` mode. Pass the plan step's `changed` output. |
| `base-branch` | `master` | branch the bump commit is pushed to |
| `deploy-workflow` | — | workflow file to dispatch once after publishing, with a `packages` input holding the plan JSON |

### Outputs

| output | notes |
|---|---|
| `changed` | comma-separated names of packages this push touched |
| `packages` | JSON array of `{ "name", "version", "previous" }` |
| `message` | the bump commit message, subject and body |
| `released` | `"true"` when at least one package was released |

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
- `bump` must be the last job: it advances `versions.json`, which downstream
  consumers read.

## Development

```sh
bash tests/run.sh
```

26 fixture-based checks covering the version math, the state file, change
detection, and the emitted commit.
