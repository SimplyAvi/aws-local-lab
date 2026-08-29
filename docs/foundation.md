# Foundation layer notes (FR-1)

Reference for the sibling tracks so they don't re-derive this.

## Pinned image tags

| Mode | Image | Why this pin |
|---|---|---|
| **Default (no token)** | `localstack/localstack:4.14.0` | The **last LocalStack release that boots with no auth token** (`2026.03.0`+ exit `55` without one). Community service set, ~30 services - see [`fidelity-matrix.md`](fidelity-matrix.md). Immutable, reproducible, CI-friendly. Used by both `docker-compose.yml` (default) and `docker-compose.no-token.yml`. Explicit pin, never `latest` (NFR-4). |
| **Paid Pro (optional)** | `localstack/localstack:latest` + a **paid** `LOCALSTACK_AUTH_TOKEN` | Only needed to reach the Pro service set (ELBv2/ALB, ECS/ECR/EKS, EC2 & App Auto Scaling, RDS/Aurora, ElastiCache, Cognito, API Gateway v2, ...). Set `LOCALSTACK_IMAGE=localstack/localstack:latest` in `.env`. A **free** ("Hobby") token adds **nothing** over the community image. |
| **Extra-conservative fallback** | `localstack/localstack:3.8.1` | An older tokenless community line, kept documented only as a fallback if `4.14.0` ever misbehaves. Set `LOCALSTACK_IMAGE=localstack/localstack:3.8.1`. |

`4.14.0` was boot-tested tokenless: `make up NO_TOKEN=1` -> ~35 community
services `available`, `s3 mb` / `s3 ls` succeed, `make reset` cleans up.

> **Token mode is optional and paid.** There is no "free tier that unlocks more
> services". The only thing an auth token buys on the free plan is the ability
> to boot a `2026.x` image at all; the service set is identical to the community
> image. Real extra services require a paid **Base** tier ($39-45/mo) or higher.
> Full breakdown: [`fidelity-matrix.md`](fidelity-matrix.md).

## Health-endpoint contract

```
GET http://localhost:${EDGE_PORT:-4566}/_localstack/health
```

Response shape:

```json
{
  "services": { "s3": "available", "lambda": "running" },
  "edition": "community",
  "version": "4.14.0"
}
```

Service states:

| State | Meaning |
|---|---|
| `available` | Service can be loaded; not started yet (lazy loading). |
| `running`   | Service has been invoked at least once and is live. |
| `disabled`  | Excluded from a narrowed `SERVICES` list. |
| `error`     | Failed to start. |

> **Pro-only services do not appear in `/_localstack/health` at all** on the
> community image - they are absent from the JSON, not listed as `disabled`.
> Calling one (`elbv2`, `ecs`, `rds`, `cognito-idp`, `apigatewayv2`, ...)
> returns `501 / InternalFailure ... not yet implemented or pro feature`. See
> [`fidelity-matrix.md`](fidelity-matrix.md).

- Edge reachable + any JSON body => exit 0.
- Connection refused / timeout => exit 1 (this is what `make status` keys on).
- `bin/health-check.sh` renders this as a sorted `service -> state` table,
  colorized on a TTY, plain otherwise (`NO_COLOR` also forces plain).

## Network / volume contract

| Resource | Name | Notes |
|---|---|---|
| Docker network | `aws-local-lab` | **External**, created by `make up` (or `make network`) if absent. Sibling compose projects join with `networks: { aws-local-lab: { external: true } }`. |
| Named volume | `aws-local-lab-data` | Mounted at `/var/lib/localstack`. `PERSISTENCE=1` is a **paid** feature and a no-op on the community image (see [`fidelity-matrix.md`](fidelity-matrix.md)); regression baselines use code-as-baseline. `make reset` removes the volume. |
| Container name | `aws-local-lab` | `make shell` execs into it. |
| Docker socket | `/var/run/docker.sock` | Bind-mounted for Lambda (sibling-container execution). |

## Knobs

All optional, all with working defaults - see `.env.example`. Key ones:
`LOCALSTACK_AUTH_TOKEN`, `LOCALSTACK_IMAGE`, `PERSISTENCE`, `SERVICES`,
`EDGE_PORT`, `DEBUG`.
