# Foundation layer notes (FR-1)

Reference for the sibling tracks so they don't re-derive this.

## Pinned image tags

| Mode | Image | Why this pin |
|---|---|---|
| **Token (default)** | `localstack/localstack:4.9.0` | Current LocalStack 4.x line (2026 free tier, auth-token based). Explicit minor+patch pin, never `latest` (NFR-4). Bump deliberately after checking the [LocalStack changelog](https://docs.localstack.cloud/references/changelog/). Override per-checkout with `LOCALSTACK_IMAGE` in `.env`. |
| **No-token** | `localstack/localstack:3.8.1` | Last pre-2026 community line that boots fully offline with **no auth token and no sign-up prompt**. Lets the lab + its tests run on a fresh machine or in CI without the captain's personal token (D-2). Layered via `docker-compose.no-token.yml` (`make up NO_TOKEN=1`). |

Both tags were confirmed to exist on Docker Hub and the no-token image was
boot-tested: `make up NO_TOKEN=1` -> 35 community services `available`,
`s3 mb` / `s3 ls` succeed, `make reset` cleans up.

The 3.x -> 4.x jump does not change the health contract or the edge port, so
sibling tracks can develop against either.

## Health-endpoint contract

```
GET http://localhost:${EDGE_PORT:-4566}/_localstack/health
```

Response shape:

```json
{
  "services": { "s3": "available", "lambda": "running", "kms": "disabled" },
  "edition": "community",
  "version": "3.8.1"
}
```

Service states:

| State | Meaning |
|---|---|
| `available` | Service can be loaded; not started yet (lazy loading). |
| `running`   | Service has been invoked at least once and is live. |
| `disabled`  | Excluded (e.g. not in a narrowed `SERVICES` list, or pro-only). |
| `error`     | Failed to start. |

- Edge reachable + any JSON body => exit 0.
- Connection refused / timeout => exit 1 (this is what `make status` keys on).
- `bin/health-check.sh` renders this as a sorted `service -> state` table,
  colorized on a TTY, plain otherwise (`NO_COLOR` also forces plain).

## Network / volume contract

| Resource | Name | Notes |
|---|---|---|
| Docker network | `aws-local-lab` | **External**, created by `make up` (or `make network`) if absent. Sibling compose projects join with `networks: { aws-local-lab: { external: true } }`. |
| Named volume | `aws-local-lab-data` | Mounted at `/var/lib/localstack`. `PERSISTENCE=1` makes state survive restarts. `make reset` removes it. |
| Container name | `aws-local-lab` | `make shell` execs into it. |
| Docker socket | `/var/run/docker.sock` | Bind-mounted for Lambda (sibling-container execution). |

## Knobs

All optional, all with working defaults - see `.env.example`. Key ones:
`LOCALSTACK_AUTH_TOKEN`, `LOCALSTACK_IMAGE`, `PERSISTENCE`, `SERVICES`,
`EDGE_PORT`, `DEBUG`.
