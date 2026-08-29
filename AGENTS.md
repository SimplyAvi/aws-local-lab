# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Foundation (FR-1, `lab-core`)

- Core stack: `docker-compose.yml` (token mode, `localstack/localstack:4.9.0`) +
  `docker-compose.no-token.yml` (pinned `3.8.1`, no token). Drive it all via the
  `Makefile`; `make up NO_TOKEN=1` for the offline path.
- Pinned tags, the `/_localstack/health` contract, and the network/volume names
  are recorded in [`docs/foundation.md`](docs/foundation.md) - read that before
  building on the lab.
- External Docker network `aws-local-lab` and named volume `aws-local-lab-data`
  are the integration seams. `make up` creates the network; `make reset` wipes both.
- Sibling tracks add Makefile targets below the `>>> sibling-track targets`
  marker and README subsections under their own headings to avoid collisions.
- Seam dirs `terraform/`, `examples/`, `integration/` are stubs for sibling tracks.
- Shell scripts must stay `shellcheck`-clean (NFR-7).

## Sample app (FR-3, `lab-sampleapp`)

- `examples/serverless-crud/`: API Gateway (REST) -> Lambda -> DynamoDB, plus S3
  presign + SQS/worker-Lambda event path. Deployed by a flat `deploy.sh` over
  `bin/awslocal` (not Terraform - the tracks land in parallel). Targets:
  `make sample-deploy` / `sample-test` / `sample-destroy`, all honour `EDGE_PORT`.
- The e2e test is stdlib-only Python (`test/e2e_test.py`) - no pip installs.
- LocalStack quirks it works around (reserved DynamoDB words, cross-container
  `AWS_ENDPOINT_URL`, presigned-URL host rewrite, `_user_request_` URL format) are
  documented in `examples/serverless-crud/README.md` - read that before changing it.

## Integration kit + load harness (FR-4 / FR-5, `integration/`)

- Everything is containerised and joins the external `aws-local-lab` network; no
  host tooling beyond Docker. See [`integration/README.md`](integration/README.md)
  and [`integration/load-harness/README.md`](integration/load-harness/README.md).
- `make integrate-smoke` (Python + Node example containers), `make lab-seed`
  (regression baseline), `make load-up|load-run|load-fault|load-down`.
- Community LocalStack does **not** durably persist S3/DynamoDB across restarts
  (Pro-only). Regression baseline is wipe + `lab-seed`, not snapshot/restore.
- Traefik pinned at `v3.6` - `v3.3` fails to talk to Docker Desktop's daemon
  (Docker 29 API). Docker Desktop does not auto-restart a `pumba kill`ed
  container; re-run `make load-up` to restore replica count.
- If host port 4566 is busy (parallel lab instances), pass `EDGE_PORT=<port>`
  to every `make` target; in-network clients always use `aws-local-lab:4566`.

## Terraform (FR-2, `lab-terraform`)

- Stacks in `terraform/` - full guide in [`terraform/README.md`](terraform/README.md).
  Root modules `foundation/` (VPC/subnets/IGW/SGs) and `system-design/`
  (ALB+ECS+AutoScaling); shared code in `terraform/modules/`.
- Local wiring is a committed `providers.tf` per root module (an `endpoints {}`
  block, dummy creds), NOT `tflocal` - rationale in `terraform/README.md`. Every
  other `.tf` stays real-AWS valid. Endpoint default is `127.0.0.1:4566`
  (`localhost` -> `::1` fails against LocalStack).
- Pinned: Terraform `1.5.7` (in `terraform/.bin/` via `make tf-install`),
  `hashicorp/aws` `5.83.1` (locked, multi-platform).
- **`elbv2` / `elb` / `ecs` / `autoscaling` / `application-autoscaling` are
  LocalStack Pro-only at every version.** `foundation` applies/destroys on the
  no-token image; `system-design` only `validate`s + `plan`s there and needs Pro
  or real AWS to `apply`. Do not "fix" this by rescoping - it is documented.
- Make targets (below the sibling marker): `tf-install`, `tf-validate`,
  `tf-fmt-check`, `tf-foundation-apply`/`-destroy`,
  `tf-system-design-apply`/`-destroy`, `tf-plan-all`, `tf-destroy-all`.
- Keep `terraform fmt -check -recursive` and `terraform validate` clean.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
