# Integration kit (`lab-integration`, FR-4 / FR-5)

Attach any external project to the lab and run it - containerised, stateless,
portable - against LocalStack. Plus a real Layer 3 load / fault harness
([`load-harness/`](load-harness/README.md)).

> Read [`../README.md`](../README.md) (requirements) and
> [`../docs/foundation.md`](../docs/foundation.md) (network / volume / health
> contract) first. This track only adds to `integration/`, Makefile targets
> below the `>>> sibling-track targets` marker, and this README section.

---

## 1. Attach any project to the lab

The lab is one LocalStack container named **`aws-local-lab`** on the **external
Docker network `aws-local-lab`**, with a named volume `aws-local-lab-data`.

| From | Endpoint | Notes |
|---|---|---|
| The host (CLI, tests, `bin/awslocal`) | `http://localhost:4566` | Or `http://localhost:$EDGE_PORT` if you overrode the port. |
| A container **on the `aws-local-lab` network** | `http://aws-local-lab:4566` | Always port `4566` inside the network, regardless of the host port. |

Credentials are dummy but must be non-empty. Region is arbitrary; the lab
standardises on `us-east-1`.

```
AWS_ENDPOINT_URL=http://aws-local-lab:4566   # or http://localhost:4566 from the host
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_DEFAULT_REGION=us-east-1
```

### Join the network from another Compose project

```yaml
# your project's docker-compose.yml
networks:
  aws-local-lab:
    external: true

services:
  app:
    networks: [aws-local-lab]
    environment:
      AWS_ENDPOINT_URL: http://aws-local-lab:4566
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      AWS_DEFAULT_REGION: us-east-1
```

Bring the lab up first (`make up NO_TOKEN=1`) - it creates the network. If your
project starts before the lab, run `make network` once.

---

## 2. One-command wiring: `aws-local-env.sh`

[`aws-local-env.sh`](aws-local-env.sh) emits ready-to-use configuration and
auto-detects whether it is running on the host or inside the shared network
(it checks whether the name `aws-local-lab` resolves).

```sh
# Env file to source into a host shell / test runner:
./integration/aws-local-env.sh > .aws-local.env && source .aws-local.env

# Compose override snippet for a containerised project:
./integration/aws-local-env.sh --compose > docker-compose.override.yml

# Force a mode when auto-detection can't decide:
./integration/aws-local-env.sh --host      # localhost:$EDGE_PORT
./integration/aws-local-env.sh --network   # aws-local-lab:4566
```

`EDGE_PORT` is honoured for the host endpoint (`EDGE_PORT=4599 ./integration/aws-local-env.sh`).
The generated `.aws-local.env` is gitignored.

---

## 3. Client snippets (generic)

No first integration target exists yet; these are copyable starting points.
Each reads `AWS_ENDPOINT_URL` and falls back to `http://aws-local-lab:4566`, and
ships a `Dockerfile` proving it runs containerised against the lab network.

| Path | Stack | Contents |
|---|---|---|
| [`examples/python/`](examples/python/) | `boto3` | `client.py` (client/resource factory) + `smoke.py` (S3 put/get, DynamoDB round-trip) |
| [`examples/node/`](examples/node/) | `@aws-sdk/client-s3` / `client-dynamodb` v3 | `client.mjs` (factory, `forcePathStyle` for S3) + `smoke.mjs` (same smoke) |

### `make integrate-smoke`

Brings the lab up if needed (no-token), builds both example images, runs each
smoke container **on the `aws-local-lab` network**, and asserts success.

```
$ make up NO_TOKEN=1 && make integrate-smoke
...
[python] S3 put/get OK  s3://integration-smoke-py/obj-... (42 bytes)
[python] DynamoDB round-trip OK  integration-smoke-py/...
[python] SMOKE PASS
[node] S3 put/get OK  s3://integration-smoke-node/obj-... (42 bytes)
[node] DynamoDB round-trip OK  integration-smoke-node/...
[node] SMOKE PASS
integrate-smoke PASS
```

(If `4566` is taken - e.g. another lab instance - bring the lab up on another
port and pass it through: `make up NO_TOKEN=1 EDGE_PORT=4567 && make integrate-smoke EDGE_PORT=4567`.
The smoke containers still reach LocalStack at `aws-local-lab:4566` inside the
network.)

---

## 4. Regression-baseline workflow

**Goal:** run a project's tests against a known lab state, then return to it.

### The honest constraint

`PERSISTENCE=1`, the state save/restore API (`POST /_localstack/state/save`),
and Cloud Pods are **paid (Base/Ultimate) features**. On the community image
verified live: the state save endpoint returns **HTTP 404**, and `PERSISTENCE=1`
writes **nothing** to the volume on shutdown - an S3 bucket created before a
container recreate is gone afterwards. A volume tar of a stopped community
container therefore captures almost nothing useful. See
[`../docs/fidelity-matrix.md`](../docs/fidelity-matrix.md).

### The baseline is code, not a snapshot (code-as-baseline)

The baseline is reproducible from source: a `make reset`, the committed
Terraform, and a deterministic seed script. "Restore" = wipe and re-run those.

```sh
make reset NO_TOKEN=1 && make up NO_TOKEN=1     # fresh LocalStack 4.14.0
make tf-foundation-apply                        # deterministic infra from terraform/
make lab-seed NO_TOKEN=1                        # deterministic seed data - idempotent
# ... run your project's tests, which mutate lab state ...
# back to baseline: repeat the three lines above
```

[`seed.sh`](seed.sh) is an **example** baseline (two S3 buckets + one DynamoDB
table). Replace its body with your project's fixtures; keep every call
idempotent. The baseline is then the git tree - diffable, reviewable, and it
survives LocalStack upgrades for free.

### Optional speed cache: `make lab-snapshot` / `make lab-restore`

If `reset` + re-apply + re-seed is too slow for a tight loop, `make lab-snapshot`
tars the `aws-local-lab-data` volume (via a throwaway `alpine` container) and
`make lab-restore` untars it back. **This is a cache, never the source of
truth:** it is whole-volume and all-or-nothing, version-bound to the exact
LocalStack image, and only partially populated (many services keep state in
memory, not on the volume). The `reset` + re-apply path above must always work
on its own. `integration/.snapshots/` is gitignored.

---

## 5. Load / system-design harness (FR-5)

See [`load-harness/README.md`](load-harness/README.md). Quick version:

```sh
make load-up LOAD_REPLICAS=3      # Traefik + 3 app replicas on the lab network
make load-run LOAD_VUS=20         # k6 through the balancer
make load-fault                   # freeze random replicas mid-test (pumba)
make load-down
```

---

## 6. Make targets (this track)

| Target | Does |
|---|---|
| `make integrate-smoke` | Build + run the Python and Node example smoke containers against the lab. |
| `make lab-seed` | (Re)create the baseline lab resources (`seed.sh`). |
| `make lab-snapshot` / `make lab-restore` | Tar / untar the `aws-local-lab-data` volume (`SNAPSHOT_NAME`, default `baseline`). Optional speed cache only, **not** a source of truth - see §4. |
| `make load-up` / `make load-run` / `make load-fault` / `make load-down` / `make load-ps` | Layer 3 harness lifecycle. |

Knobs: `LOAD_REPLICAS` (3), `LOAD_VUS` (20), `LOAD_HOLD` (20s), `LOAD_LB_PORT`
(8080), `FAULT_INTERVAL` (15s), `FAULT_DURATION` (8s), `EDGE_PORT` (4566),
`SNAPSHOT_NAME` (baseline).
