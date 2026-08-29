# Fidelity matrix - what actually works locally

This is the **authoritative** service-coverage reference for `aws-local-lab`.
Every other doc (README §2, `docs/foundation.md`, `terraform/README.md`,
`AGENTS.md`) defers here. It is ported from the FR-6 `lab-research` deliverable
and its findings were verified live against `localstack/localstack:3.8.1` and
`:4.14.0` on 2026-08-29.

## The one fact that governs everything

**A free ("Hobby") LocalStack auth token unlocks nothing** beyond the
unauthenticated community image (~30 services). The only reason to hold a free
token is that images from `2026.03.0` on refuse to boot without one
(`exit 55`). `localstack/localstack:4.14.0` is the **last release that boots
with no token** and is this lab's default image.

The "Pro service set" - ELBv2/ALB & ELB classic, ECS, ECR, EKS, EC2 Auto
Scaling, Application Auto Scaling, RDS/Aurora, ElastiCache, Cognito, API Gateway
v2 (HTTP + WebSocket), SES v2, Glue, Athena, Redshift, AppSync - requires a
**paid** tier (Base $39-45/mo/seat and up) *and* the `:latest` / `2026.x` image.
On the community image every one of those returns
`501 / InternalFailure ... not yet implemented or pro feature`, and they do
**not** appear in `/_localstack/health` at all.

## Legend

| Rating | Meaning |
|---|---|
| **data-plane** | Real behaviour exercised end to end - objects stored, queries run, messages delivered, code executed. |
| **control-plane** | API calls succeed and the resource is describable, but nothing real runs (no traffic, no VM, no managed engine). |
| **none** | Not implemented in this edition - the call errors (`501` / `InternalFailure ... pro feature`). |

Columns:

- **Free / community** = `localstack/localstack:4.14.0` (no token) - the lab
  default. A free "Hobby" token on `:latest` yields the identical feature set.
- **Paid (Base+)** = `localstack/localstack:latest` with a **paid**
  `LOCALSTACK_AUTH_TOKEN`.
- **Moto** = `moto` `@mock_aws` - in-process Python mock, used for fast unit
  tests only.

## Matrix

| AWS service | Free / community | Paid (Base+) | Moto | Notes |
|---|---|---|---|---|
| S3 (objects, versioning, presign, multipart) | **data-plane** | data-plane | data-plane | Path-style addressing required (`s3_use_path_style`). |
| S3 -> Lambda event notifications | **data-plane** | data-plane | partial | Moto fires only within the mock process. |
| DynamoDB (queries, TTL, transactions) | **data-plane** | data-plane | data-plane | Embedded DynamoDB-Local (Java). |
| DynamoDB Streams | **data-plane** | data-plane | data-plane | |
| DynamoDB / SQS -> Lambda (event source mapping) | **data-plane** | data-plane | partial | Used by the sample app worker. Moto delivers only in-process. |
| Lambda (execution) | **data-plane** | data-plane | data-plane (Docker) | Runs each fn as a sibling Docker container (needs `/var/run/docker.sock`, mounted by `lab-core`). Build zips for `linux/amd64` or arm64, not macOS. |
| API Gateway REST (v1) | **data-plane** | data-plane | control-plane | Invoke URL `.../restapis/<id>/<stage>/_user_request_/<path>`. Moto stores but does not route. |
| API Gateway HTTP API (v2) + WebSocket | **none** | control-plane | control-plane | Pro-only. |
| API Gateway authorizers (Lambda / JWT) | partial (v1) / none (v2) | partial+ | control-plane | Not reliably testable on the free tier. |
| SQS | **data-plane** | data-plane | data-plane | |
| SNS (+ SNS -> SQS fan-out) | **data-plane** | data-plane | data-plane | |
| EventBridge (rules, buses, targets) | **data-plane** | data-plane | control-plane | Moto stores rules but does not deliver to targets. |
| EventBridge Scheduler | **data-plane** | data-plane | stub | |
| Kinesis Data Streams | **data-plane** | data-plane | data-plane | Kinesis-Mock (Scala) engine. |
| Kinesis Firehose -> S3 | control-plane / partial | control-plane / partial | control-plane | Delivery works; batching/timing differ from AWS. |
| Step Functions | **data-plane** | data-plane | control-plane | Real state execution (Map/Parallel/Choice). Moto does not execute. |
| Secrets Manager | **data-plane** | data-plane | data-plane | Rotation is stubbed. |
| SSM Parameter Store | **data-plane** | data-plane | data-plane | Run Command / Session Manager not real. |
| KMS | **data-plane** | data-plane | data-plane | Real crypto (envelope encryption, data keys, signing). |
| STS | **data-plane** | data-plane | data-plane | Account `000000000000`. Trust policies not enforced. |
| IAM | **control-plane** | control-plane (partial enforce) | control-plane | Not enforced by default. `ENFORCE_IAM=1` adds partial, buggy evaluation. |
| CloudFormation | **data-plane** | data-plane | data-plane (mock) | A CFN stack of Pro resources fails on the Pro resource. |
| CloudWatch Logs | **data-plane** | data-plane | data-plane | Lambda/EventBridge write here for real. |
| CloudWatch Metrics | **data-plane** | data-plane | data-plane | Custom metrics only; no AWS-emitted service metrics. |
| CloudWatch Alarms | control-plane / partial | control-plane / partial | control-plane | State evaluation against metric data is not reliable. |
| EC2 (instances) | **control-plane** | control-plane | control-plane | `run-instances` returns `running` with fake IPs. No real compute. |
| VPC / subnets / route tables / IGW / NAT / SG | **control-plane** | control-plane | control-plane | No packet routing. This is `terraform/foundation/` and it applies cleanly. |
| Route 53 | **control-plane** (+ built-in resolver) | control-plane | control-plane | The built-in DNS server can resolve records - niche data-plane, needs container DNS on 53. |
| **ELBv2 (ALB / NLB)** | **none** | control-plane - **no HTTP dataplane** | control-plane | Free: `elbv2 create-load-balancer` -> 501. Paid: describable, but no request is ever balanced. Real balancing = Layer 3 harness. |
| ELB classic (v1) | **none** | control-plane | control-plane | |
| **EC2 Auto Scaling (ASG)** | **none** | control-plane (number only) | control-plane | `DesiredCapacity` drives nothing even on paid. |
| **Application Auto Scaling** | **none** | control-plane | control-plane | |
| **ECS** | **none** | control-plane + runs tasks as Docker containers | control-plane | Paid ECS actually runs Fargate-style tasks - a real reason to consider Base tier. |
| **ECR** | **none** | real registry (local Docker) | control-plane | |
| **EKS** | **none** | real `k3d` cluster | control-plane | For real Kubernetes use `k3d`/`kind` directly, not LocalStack. |
| **RDS / Aurora** | **none** | real Postgres/MySQL/MariaDB process | control-plane | Free-tier substitute: run a real `postgres:16` / `mysql:8` container on the shared network. |
| **ElastiCache** | **none** | (Pro) | control-plane | Free-tier substitute: a real `redis:7` container. |
| **Cognito (IDP + Identity)** | **none** | real JWTs, hosted-UI / SRP flows | control-plane | Free-tier substitute: a `keycloak` container, or stub the token verifier. |
| SES (v1) | **data-plane (capture)** | data-plane (capture) | data-plane (capture) | Mail captured, not delivered - `GET /_localstack/ses`. |
| SES v2 | **none** | control-plane | control-plane | Use SES v1 APIs on the free tier. |
| Glue / Athena / AppSync | **none** | (Pro big-data / Pro) | control-plane | |
| Redshift | **control-plane** | control-plane | control-plane | In the community health set but control-plane only - no query engine. |
| OpenSearch / ES | data-plane (slow first start) | data-plane | control-plane | Launches a real OpenSearch process on first domain create. |

## Persistence

`PERSISTENCE=1`, `POST /_localstack/state/save`, and Cloud Pods are **paid
(Base/Ultimate)** features. On the community image the state save endpoint
returns **HTTP 404** and `PERSISTENCE=1` writes nothing on shutdown. Regression
baselines therefore use **code-as-baseline**: `make reset` + re-apply Terraform
+ `make lab-seed`. See [`../integration/README.md`](../integration/README.md) §4.

## Load balancing / "system design"

There is **no load-balancer dataplane anywhere** - not on the free tier (no
`elbv2` object at all), not on paid (control-plane only). Real request
distribution, failover, and saturation behaviour are built from real containers
in `lab-integration`'s Layer 3 harness (Traefik + N replicas + k6 + pumba). See
[`../integration/load-harness/README.md`](../integration/load-harness/README.md).

## How to read this for testing

- **~20 services are genuinely real** on the free tier - the event-driven
  serverless + storage + config surface. Enough to build and regression-test
  the large majority of serverless apps.
- **The entire compute + networking dataplane tier is absent** on the free
  tier: ELBv2, ECS, EKS, ASG, App Auto Scaling, ECR = `none`;
  VPC/EC2/SG/Route53 = describable shells; RDS/ElastiCache/Cognito = `none`.
- **Moto** is a strict subset in behaviour but a superset in control-plane
  breadth - it will "create" an ALB, ECS cluster, RDS instance, Cognito pool,
  all mocks. Use Moto in `tests/unit`; use LocalStack in `tests/integration`.
