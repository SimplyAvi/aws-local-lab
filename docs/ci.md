# CI - the green gate

The pipeline lives in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
and runs on every `pull_request` and on `push` to `main`. Superseded runs on the
same ref are cancelled (`concurrency`). Every action is pinned to a released
tag; the whole pipeline runs on the tokenless `localstack/localstack:4.14.0`
image and never applies a paid-tier resource.

Target wall time: well under ~12 min (the `e2e` job dominates at ~6-9 min).

## Jobs

| Job          | What it proves | Docker daemon |
|--------------|----------------|---------------|
| `lint`       | `ci/lint.sh`: `shellcheck` on `bin/*` and every `*.sh`; `docker compose config -q` for the core stack, the `docker-compose.no-token.yml` overlay, and every `integration/` compose file; `make -n` parses the everyday targets. | no |
| `terraform`  | `terraform fmt -check -recursive terraform/`; `init -backend=false` + `validate` for `terraform/foundation` and `terraform/system-design`, using the repo-pinned Terraform `1.5.7`. No `apply`. | no |
| `e2e`        | The real gate. `make up NO_TOKEN=1`, wait for `/_localstack/health` + core services (`ci/wait-for-health.sh`), `make status`, then `make sample-deploy && make sample-test` (behavioural serverless-CRUD e2e), `make tf-foundation-apply && make tf-destroy-all` against the running lab, and `make integrate-smoke` (Python + Node client containers). Uploads LocalStack logs as an artifact on failure, always tears down. | yes |
| `load-smoke` | `docker compose -f integration/load-harness/docker-compose.yml config -q` + `build app`. A full k6 run is deliberately omitted - see the note in the workflow. | yes |
| `secrets`    | `gitleaks` scan (full history on push, PR commit range on pull_request). Fails on any finding. | no |

## Helper scripts (`ci/`)

- `ci/lint.sh` - the `lint` job body; also runnable locally.
- `ci/wait-for-health.sh [timeout]` - bounded poll of the edge until the core
  community services report `available`/`running`. Absorbs cold-start races in
  CI without weakening any test. Honours `LAB_ENDPOINT` and `CORE_SERVICES`.

Both are `shellcheck`-clean and portable (no bash 4 built-ins).

## CI-only knobs

No app, infra, or test *logic* is forked for CI. The only environment nudge is
`LAB_ENDPOINT` / `EDGE_PORT`, already honoured by every `make` target and by the
sample-app scripts. `ci/wait-for-health.sh` reads `LAB_ENDPOINT` too.

## Required checks for merge

Once this workflow is green on a PR, make these the merge gate:

**Required status checks** (exact job names):

- `lint`
- `terraform`
- `e2e`
- `secrets`

`load-smoke` is informational (a fast buildability check) and is **not**
required.

## Branch-protection settings to apply

Apply on `main` via **Settings -> Branches -> Branch protection rules** (or
`Rulesets`). firstmate / the captain applies these through repo settings - the
workflow does **not** set them.

- Branch name pattern: `main`
- [x] Require a pull request before merging
  - [x] Require approvals: 1
  - [x] Dismiss stale pull request approvals when new commits are pushed
- [x] Require status checks to pass before merging
  - [x] Require branches to be up to date before merging
  - Required checks: `lint`, `terraform`, `e2e`, `secrets`
- [x] Require conversation resolution before merging
- [x] Do not allow bypassing the above settings (no bypass list; applies to admins)
- [ ] Allow force pushes - disabled
- [ ] Allow deletions - disabled

`gh` equivalent (run by whoever owns repo settings):

```sh
gh api -X PUT repos/SimplyAvi/aws-local-lab/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["lint", "terraform", "e2e", "secrets"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "required_approving_review_count": 1
  },
  "required_conversation_resolution": true,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```
