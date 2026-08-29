# terraform/ - Terraform stacks (FR-2, `lab-terraform`)

Infrastructure-as-code for the lab, written to be **byte-for-byte valid against
real AWS**. The only local-specific code is a single `providers.tf` per root
module; delete those two files and `terraform init -reconfigure` to target real
AWS.

## Layout

| Path | What |
|---|---|
| `foundation/` | Root module: VPC, 2 public subnets across AZs, internet gateway + route table, ALB & service security groups. The network baseline. Applies cleanly on the no-token LocalStack image. |
| `system-design/` | Root module: Application Load Balancer + HTTP listener + target group, ECS cluster + Fargate task definition + service, Application Auto Scaling target + target-tracking policy. Reads `foundation` outputs via `terraform_remote_state`. **Needs a paid LocalStack tier (Base+) or real AWS to `apply`** - see [Fidelity](#fidelity) / [Known gaps](#known-gaps). |
| `modules/network/` | Shared VPC / subnet / IGW / route-table module. |
| `modules/ecs-service/` | Shared ALB + ECS + Auto Scaling module. |
| `scripts/tf-install.sh` | Installs the pinned Terraform into `terraform/.bin/` (gitignored). |
| `.bin/` | Local pinned Terraform (gitignored). |

## Versions

Pinned in each root module's `versions.tf` and locked in `.terraform.lock.hcl`
(checksums for linux/darwin x amd64/arm64):

| Tool | Version | Notes |
|---|---|---|
| Terraform | **1.5.7** | Last MPL-licensed line; adequate for a local lab and safe to reference from a public repo. `required_version = ">= 1.5.0, < 1.6.0"`. |
| `hashicorp/aws` provider | **5.83.1** | Exact pin. Bump deliberately. |

`make tf-install` fetches Terraform 1.5.7 into `terraform/.bin/`. The Makefile
prefers that binary and falls back to a `terraform` on `PATH`.

## Local wiring: committed `providers.tf` (not `tflocal`)

The brief allows either the `tflocal` wrapper (from the `terraform-local` pip
package) **or** a committed provider `endpoints {}` block. This track uses the
**committed `providers.tf`** because:

- **No runtime dependency.** `tflocal` needs Python + pip (and on modern distros a
  venv to get around PEP 668). A committed file needs nothing but Terraform.
- **Deterministic and reviewable.** The exact local override is in version
  control, in one file, not synthesized at run time.
- **CI-friendly.** Works unchanged in any environment that has Terraform.
- **Single-file isolation.** Every other `.tf` file is real-AWS Terraform. The
  local-only surface is exactly `foundation/providers.tf` and
  `system-design/providers.tf`, which set:
  - `endpoints {}` -> `http://127.0.0.1:4566` for the services each stack uses
  - `access_key` / `secret_key` = `test` (dummy)
  - `s3_use_path_style = true`
  - `skip_credentials_validation`, `skip_metadata_api_check`,
    `skip_requesting_account_id` = `true`
  - one input variable, `localstack_endpoint` (default `http://127.0.0.1:4566`)

> The default endpoint uses `127.0.0.1`, not `localhost`, because LocalStack
> binds IPv4 only and `localhost` resolves to `::1` first on many machines
> (`dial tcp [::1]:4566: connect: connection refused`). Override with
> `-var='localstack_endpoint=...'` or `TF_VAR_localstack_endpoint` if needed.

## State

Local backend (`backend "local" {}`) is the committed default. Rationale: this is
a single-user local lab, the state carries no secrets worth protecting, and a
remote backend (S3 + DynamoDB lock table) would itself have to be emulated.
`*.tfstate` is gitignored. `system-design` reads `../foundation/terraform.tfstate`
directly via `terraform_remote_state` (path overridable with
`-var=foundation_state_path=...`).

## Running

Bring the lab up first (no-token image, from the repo root):

```sh
make up NO_TOKEN=1
```

Then:

| Command | Does |
|---|---|
| `make tf-install` | Install pinned Terraform into `terraform/.bin/`. |
| `make tf-validate` | `terraform validate` every root module (backend-less init). |
| `make tf-fmt-check` | `terraform fmt -check -recursive` across `terraform/`. |
| `make tf-foundation-apply` | Apply the foundation stack. |
| `make tf-foundation-destroy` | Destroy the foundation stack. |
| `make tf-system-design-apply` | Apply the system-design stack (fails with a pointer here on the community image - see below). |
| `make tf-system-design-destroy` | Destroy the system-design stack (cleans up any partially-created resources). |
| `make tf-plan-all` | Plan both stacks in dependency order. Runs clean on the no-token image. |
| `make tf-destroy-all` | Destroy both stacks (system-design, then foundation). |

Run stacks directly for non-default vars:

```sh
terraform/.bin/terraform -chdir=terraform/foundation apply \
  -var='localstack_endpoint=http://127.0.0.1:4599'
```

## Fidelity

Per the [three-layer model](../README.md#2-the-three-layer-model-read-this-first),
this track lives in **Layer 2 - networking & compute control plane**. Resources
are describable via the API; there is **no real traffic, no real VMs, no real
containers**. The authoritative per-service coverage reference is
[`../docs/fidelity-matrix.md`](../docs/fidelity-matrix.md).

| Resource | On the no-token (community) image | On a paid LocalStack tier (Base+) | On real AWS |
|---|---|---|---|
| VPC, subnets, internet gateway, route table, route table associations | **Real control plane** - created, described, destroyed. No packet routing. | same | real |
| Security groups + rules | **Real control plane.** IAM/SG rules are **not enforced** - nothing filters traffic locally. | same | enforced |
| `aws_availability_zones` data source | Works (returns `us-east-1a/b/...`). | works | real |
| Application Load Balancer, listener, target group (`elbv2`) | **Not available** - `elbv2` is Pro-only (HTTP 501). | control plane only - **no dataplane**, `alb_dns_name` resolves to nothing. | real dataplane |
| ECS cluster, task definition, service (`ecs`) | **Not available** - `ecs` is Pro-only (HTTP 501). | control plane only - **tasks do not actually run**. | real Fargate tasks |
| Application Auto Scaling target + policy (`application-autoscaling`) | **Not available** - Pro-only (HTTP 501). | control plane only - **no metrics, never scales**. | real scaling |
| IAM role + policy attachment (task execution role) | **Real control plane** - created and described. Not enforced. | same | enforced |
| CloudWatch log group | **Real control plane.** | same | real |

**The ALB has no real dataplane anywhere in this lab.** Even on Pro it is a
control-plane object. The real load-balancing / failover / saturation test is
`lab-integration`'s **Layer 3 harness** (Traefik + replicas + k6/Locust +
fault injection), which runs actual HTTP against real containers.

## Known gaps

`elbv2`, `elb`, `ecs`, `autoscaling`, and `application-autoscaling` are
**paid-tier-only (LocalStack Base and up) at every version** - a free "Hobby"
token does not include them. Confirmed against community images `3.8.1`, `4.5.0`,
and `4.14.0`, which return:

```
InternalFailure: The API for service 'ecs' is either not included in your
current license plan or has not yet been emulated by LocalStack.
```

Consequences and the agreed handling (brief decision: "document the gap rather
than fail the task"):

- **`foundation`**: full `apply` / `destroy` acceptance on the no-token image. ✅
- **`system-design`**: `terraform validate` and `terraform fmt -check` pass;
  `make tf-plan-all` runs clean against the no-token lab; `make
  tf-system-design-apply` is kept but stops at the first 501 and prints a pointer
  to this section. To actually `apply` it you need **LocalStack Pro** (a paid
  tier - the *free* auth token from app.localstack.cloud does **not** include
  these services) or **real AWS** (delete the two `providers.tf` files first).

If the lab later acquires a Pro token, `system-design` applies unchanged (control
plane only - still no real ALB traffic; use Layer 3 for that).

## LocalStack + Terraform sharp edges hit on this track

| Sharp edge | Detail / mitigation |
|---|---|
| **S3 path-style addressing** | Virtual-host-style S3 URLs (`bucket.s3.amazonaws.com`) don't resolve to LocalStack. `s3_use_path_style = true` is set in `providers.tf`. Not exercised by these stacks but required for any S3 backend/state work. |
| **Hard-coded ARNs / account `000000000000`** | LocalStack issues everything under account `000000000000`. `arn:aws:iam::aws:policy/...` managed-policy ARNs (used for `AmazonECSTaskExecutionRolePolicy`) are accepted as opaque strings - the policy isn't real. Never assert on account IDs in tests. |
| **IAM is not enforced** | Roles, policies, and assume-role docs are created and described but never evaluated. A task "execution role" is cosmetic locally. Don't write tests that expect an `AccessDenied`. |
| **Pro-gated control planes** | The big one for this track - see [Known gaps](#known-gaps). `terraform plan` gives no warning; the 501 only surfaces on `apply`. |
| **`localhost` vs `127.0.0.1`** | LocalStack binds IPv4; `localhost` -> `::1` fails. Endpoint default is `127.0.0.1`. |
| **Resource ordering** | `aws_ecs_service` needs its `aws_lb_listener` to exist first (AWS returns a target-group-association error otherwise); handled with an explicit `depends_on`. `terraform destroy` on a partial `apply` must run to clean up the IAM role / log group that *did* get created before the 501 - `make tf-system-design-destroy` / `tf-destroy-all` do this. |
| **Lambda packaging** | Not used by this track, but noted for `lab-sampleapp`: LocalStack runs Lambda in sibling Docker containers (needs the bind-mounted `/var/run/docker.sock`); `filename`/`s3_key` archives must be real zips and `source_code_hash` churn causes needless redeploys. |
| **Provider lock platform coverage** | A default `terraform init` only records checksums for the host platform; `.terraform.lock.hcl` here was regenerated with `terraform providers lock -platform=...` for linux/darwin x amd64/arm64 so CI on Linux doesn't re-fetch. |
