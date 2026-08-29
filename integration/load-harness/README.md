# Layer 3 load / system-design harness (FR-5)

A self-contained Compose project on the shared **`aws-local-lab`** network that
puts a **real load balancer** in front of **N interchangeable app replicas**,
drives **real HTTP load** at them, and can **inject faults** mid-test - the
behaviour LocalStack itself cannot provide.

```
        k6  ──HTTP──▶  Traefik  ──balances──▶  app ×N   ──S3 / DynamoDB──▶  LocalStack
     (load gen)      (real LB,            (stateless,                    (Layer 1,
                     health checks)       every replica equal)          shared network)
                          ▲
                        pumba  (pause / kill a random replica)
```

## What this demonstrates that LocalStack cannot

LocalStack emulates the **control plane** for ELB/ALB, EC2, ECS, Auto Scaling -
`aws elbv2 create-load-balancer` succeeds and the resource is describable, but
**no traffic is balanced, no packet is routed, nothing actually runs**. This
harness is the **data plane**, built from real containers:

| Property | LocalStack (Layer 2) | This harness (Layer 3) |
|---|---|---|
| Request distribution across replicas | described only | **real** - round-robin, measured |
| Failover when a node dies / hangs | n/a | **real** - Traefik health-checks out the bad node |
| Saturation / latency under load | n/a | **real** - p95/p99 move as VUs climb |
| Fault injection (kill, freeze, delay) | n/a | **real** - pumba |
| Application state | - | still in **Layer 1** (LocalStack S3 + DynamoDB) |

The replicas hold **zero local state** - every `POST /work` writes to S3 and
DynamoDB and reads back, so any replica can serve any request and the balancer
is free to move traffic. That is the whole point of the three-layer split:
**real system-design behaviour, real AWS-shaped state.**

## Components (all pinned, all containers)

| Service | Image | Role |
|---|---|---|
| `traefik` | `traefik:v3.6` | Load balancer, Docker service discovery, per-replica health checks (`/healthz`), access logs. Published on `localhost:${LOAD_LB_PORT:-8080}`. |
| `app` | built from [`app/`](app/) (`node:22-alpine`) | Stateless HTTP service; state in LocalStack S3 + DynamoDB. Scaled with `--scale app=N`. |
| `k6` | `grafana/k6:0.55.0` | Load generator. Scenario in [`scenarios/load.js`](scenarios/load.js). `profiles: [tools]` - not started by `load-up`. |
| `pumba` | `gaiaadm/pumba:0.11.6` | Fault injection. `profiles: [tools]`. |

### App routes

| Route | Behaviour |
|---|---|
| `GET /healthz` | 200 once S3 + DynamoDB are reachable, else 503 (Traefik uses this) |
| `GET /` | `{ replica, served, ready }` - shows which replica answered |
| `POST /work` | write object to S3 + item to DynamoDB, read the object back, return `{ id, roundtrip }` |
| `GET /work/:id` | fetch the item from DynamoDB, report which replica wrote it |

## Run it

```sh
make load-up  LOAD_REPLICAS=3          # build + start Traefik + 3 replicas
make load-run LOAD_VUS=20 LOAD_HOLD=25s   # k6 ramps to 20 VUs through the balancer
make load-fault FAULT_INTERVAL=10s FAULT_DURATION=6s   # (separate shell) freeze replicas
make load-ps
make load-down
```

`load-up` / `load-run` bring the no-token lab up automatically if it is not
already healthy. If port `4566` is taken, run the lab on another port and pass
it through (`make load-up EDGE_PORT=4567 ...`); the harness reaches LocalStack
at `aws-local-lab:4566` inside the network regardless.

## Reading the k6 output

k6 prints one block at the end. The lines that matter:

```
checks.........................: 100.00% 3300 out of 3300
http_req_failed................: 0.00%   0 out of 1980       <- error rate (threshold <5%)
http_req_duration.............: avg=6.83ms  p(90)=16.84ms  p(95)=20.8ms   <- latency (threshold p95<2s)
http_reqs.....................: 1980    65.5/s               <- throughput
replicas_seen_total...........: 660                          <- tagged by replica; confirms spread
write_latency.................: avg=15.44ms p(95)=26.42ms    <- custom: the S3+DynamoDB write path
```

- **`checks` / `http_req_failed`** - correctness. `roundtrip ok` proves the
  S3+DynamoDB write/read path held up under load.
- **`http_req_duration` p95/p99** - latency. Compare a clean run to a
  fault run to see degradation.
- **`replicas_seen_total`** broken down by the `replica` tag (in the full
  output / a k6 dashboard) shows the balancer spreading requests; a quick
  `for i in $(seq 1 9); do curl -s localhost:8080/ | jq -r .replica; done | sort | uniq -c`
  shows near-perfect round-robin (3/3/3).
- **thresholds** (`http_req_failed<0.05`, `p95<2000ms`) make `make load-run`
  exit non-zero if the system misbehaves.

### Measured on this lab (no-token image, 3 replicas, macOS/Docker Desktop)

| Run | VUs | checks | http_req_failed | p95 | throughput |
|---|---|---|---|---|---|
| Clean | 15 | 100.00% (3300/3300) | 0.00% | 20.8 ms | 65.5 req/s |
| **With fault injection** (pumba `pause`, ~1 replica frozen at a time) | 20 | 99.70% (2749/2757) | 0.24% | 46.3 ms (tail to ~6 s) | 41 req/s |

Under fault injection the frozen replica keeps a few in-flight requests hanging
until Traefik's health check (5 s interval) pulls it from rotation; new requests
land on the healthy replicas. Error rate stays well under 1% and recovers fully
when pumba unpauses the replica - visible, real failover.

## Fault injection

`make load-fault` runs pumba with the default scenario: every `FAULT_INTERVAL`,
**pause a random replica for `FAULT_DURATION`, then unpause it** - a self-healing
"node went unresponsive" scenario that is safe to loop under load. Runs until
you Ctrl-C.

Other scenarios (edit the `pumba` command or run pumba directly):

```sh
cd integration/load-harness

# Hard kill a random replica every 15s (SIGKILL). Docker Desktop does NOT
# auto-restart a killed container here, so restore capacity afterwards with
#   make load-up LOAD_REPLICAS=3      (Compose recreates the missing replicas)
docker compose --profile tools run --rm pumba \
  --random --interval 15s kill --signal SIGKILL "re2:aws-local-lab-load-harness-app-.*"

# Add 500ms +-100ms latency to a random replica's traffic for 20s (netem):
docker compose --profile tools run --rm pumba \
  --random netem --duration 20s delay --time 500 --jitter 100 \
  "re2:aws-local-lab-load-harness-app-.*"
```

`kill` demonstrates failover to a smaller pool (and, with `make load-up`
re-run, orchestrator-style replacement); `pause` / `netem delay` demonstrate a
degraded-but-present node, which is the more interesting balancer case.

## Layout

```
load-harness/
  docker-compose.yml        Traefik + app (+ k6, pumba under profile "tools")
  app/                      stateless Node service (server.mjs, Dockerfile)
  scenarios/load.js         k6 scenario (ramping VUs, write + read-back, thresholds)
  README.md                 this file
```
