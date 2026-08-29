# Troubleshooting

When something breaks, run the diagnostics tool first - it checks the whole lab
and prints a fix for every problem it finds:

```sh
make doctor              # human-readable PASS/WARN/FAIL report
make doctor JSON=1       # same, as JSON
make logs-bundle         # redacted tarball to attach when you ask for help
```

`make doctor` exits non-zero if anything is a **FAIL**. `make logs-bundle`
writes `./diagnostics/lab-diag-<ts>.tar.gz` (gitignored, secrets redacted):
the doctor report, `docker compose ps` / `logs` / resolved `config`,
`/_localstack/health`, a redacted `docker inspect` of the container,
docker/compose versions, and the git SHA.

## Symptom -> cause -> fix

| Symptom (what you see) | Cause | Fix | Caught by `make doctor`? |
|---|---|---|---|
| `Bind for 0.0.0.0:4566 failed: port is already allocated` / `make up` fails immediately | Another process or container already holds the edge port `4566`. | Stop the other process (`make doctor` names it), or set `EDGE_PORT=4599` in `.env` and pass `EDGE_PORT=4599` to every `make` target; in-network clients still use `aws-local-lab:4566`. | **Yes** - `port.4566` FAIL, names the process/container. |
| `permission denied` on `/var/run/docker.sock`, or `make up` can't talk to Docker | Your user can't reach the Docker socket (Docker Desktop not running; Linux user not in the `docker` group). | Start Docker Desktop; on Linux `sudo usermod -aG docker $USER` then log out/in. | **Yes** - `docker.daemon` FAIL. |
| Container exits right after start; `docker inspect` shows `"ExitCode": 55` | You're on a `2026.x` / `:latest` LocalStack image, which refuses to boot with no auth token. | `make up NO_TOKEN=1` (pins `localstack/localstack:4.14.0`, the last tokenless release), **or** set a **paid** `LOCALSTACK_AUTH_TOKEN` + `LOCALSTACK_IMAGE=localstack/localstack:latest` in `.env`. A free "Hobby" token adds nothing - see [`fidelity-matrix.md`](fidelity-matrix.md). | **Yes** - `container` FAIL decodes exit 55; `image.token` FAIL. |
| API call returns `501` / `InternalFailure ... not yet implemented or pro feature` (e.g. `elbv2`, `ecs`, `rds`, `cognito-idp`, `apigatewayv2`) | That service is **paid-tier only**. It isn't in the community image and never appears in `/_localstack/health`. | Use the Layer 3 harness for real load balancing (`make load-up`), or a real `postgres`/`redis`/`keycloak` container for RDS/ElastiCache/Cognito. Full per-service breakdown: [`fidelity-matrix.md`](fidelity-matrix.md). | No - expected behavior, not a lab fault. |
| First `make up` takes minutes / times out on the health wait | Initial image pull is ~300 MB. | Wait it out once; later boots take seconds. Pre-pull with `docker pull localstack/localstack:4.14.0`. Narrow `SERVICES=s3,dynamodb,lambda,sqs` in `.env` for faster eager loading. | Partly - `container` shows `running` but `edge`/`services` still failing means it's still booting; check `make logs`. |
| `make up` hangs on `waiting for the edge...` and never returns | The edge never came healthy - container crashed after start, wrong image, or the port is shadowed by another listener. | `make doctor` (from another shell) - it shows the container state, decodes the exit code, and dumps the last 30 log lines. Then `make reset NO_TOKEN=1 && make up NO_TOKEN=1`. | **Yes** - `container` + `edge` FAIL with log tail. |
| Cross-container AWS calls fail with connection refused, but host calls work | A sibling container used `http://localhost:4566` - inside a container `localhost` is that container itself. | Use `http://aws-local-lab:4566` (the container/network name) for in-network clients, or `http://localhost.localstack.cloud:4566` where a real hostname is needed. Host tools use `http://localhost:4566` / `bin/awslocal`. | **Yes** - `dns` check verifies `localhost.localstack.cloud` resolves inside the container. |
| Lambda invoke fails: `Error while creating lambda ...` / container-runtime errors / hangs | LocalStack runs each function as a **sibling Docker container** and needs the Docker socket; also the zip must be built for `linux/amd64` (or arm64), not macOS. | Confirm `docker-compose.yml` mounts `/var/run/docker.sock` and Docker Desktop file sharing allows it. Build deployment zips on Linux arch. Check `LAMBDA_*` env if you've overridden defaults. | **Yes** - `socket` check confirms the socket is mounted and readable in the container. |
| `terraform apply` on `terraform/system-design/` fails with `HTTP 501 ... not included in your current license plan` | `elbv2` / `ecs` / `application-autoscaling` are **paid-tier only** at every version. This stack `validate`s and `plan`s clean but can't `apply` on the community image. | Expected. Use `make tf-plan-all` for the free path; real load balancing is the Layer 3 harness. Needs paid LocalStack or real AWS to `apply`. See [`../terraform/README.md`](../terraform/README.md). | No - expected, documented behavior. |
| `terraform` command fails with `Error acquiring the state lock` | A previous `terraform` run was killed and left a stale lock (local backend: `.terraform.tfstate.lock.info`). | Make sure no other `terraform` is running, then `terraform force-unlock <LOCK_ID>` in that root module, or delete the stale `.terraform.tfstate.lock.info`. | No. |
| Presigned S3 URL returns `SignatureDoesNotMatch` or connection errors when opened | The URL was signed for one host (`localhost`) but is being fetched from another (`aws-local-lab`, or vice-versa); the host in the signed URL must match the client's route. | Sign and fetch with the same endpoint. From the host use `localhost:4566`; in-network use `aws-local-lab:4566`. The sample app rewrites the host - see [`../examples/serverless-crud/README.md`](../examples/serverless-crud/README.md). | No. |
| State disappears after `make restart`, even with `PERSISTENCE=1` | `PERSISTENCE=1`, `POST /_localstack/state/save`, and Cloud Pods are **paid (Base/Ultimate)** features. On the community image `PERSISTENCE=1` writes nothing on shutdown. | Rebuild baseline state from code: `make reset` + re-apply Terraform + `make lab-seed` (idempotent). `make lab-snapshot` / `lab-restore` are a volume-tar cache only. See [`fidelity-matrix.md`](fidelity-matrix.md). | Partly - `image` check reports the running edition/tag; persistence tier isn't probed directly. |
| `make status` prints raw JSON instead of a table | `jq` is not installed. | `brew install jq` / `apt install jq`. | **Yes** - the tool depends on `jq` and will say so. |
| Running image tag isn't the one you expect | `LOCALSTACK_IMAGE` set in `.env` / environment, or a container left over from another run. | `make reset NO_TOKEN=1 && make up NO_TOKEN=1`. | **Yes** - `image` WARN on drift from the `docker-compose*.yml` pin. |
| `aws-local-lab` network missing / sibling compose project can't start (`network aws-local-lab declared as external, but could not be found`) | The external Docker network was pruned (e.g. by `make reset`) and not recreated. | `make up` recreates it, or `docker network create aws-local-lab`. | **Yes** - `network` FAIL. |

## Knowledge-vault integration point

`bin/diagnose.sh --emit-finding` prints a finding stub in the
`hirdr-knowledge` ticket front-matter format (see that repo's
`templates/finding.md` / `bin/kb-ticket`) - overall verdict, every non-PASS
check with its fix, and the container log tail. It has **no hard dependency**
on that repo being present. Pipe it into a file and drop it into the vault, or
attach it to a ticket:

```sh
bin/diagnose.sh --emit-finding > finding-$(date -u +%Y%m%dT%H%M%SZ).md
```

## Still stuck?

Run `make logs-bundle` and attach `diagnostics/lab-diag-<ts>.tar.gz` to your
help request. It is secret-free (tokens and secret-shaped env values are
replaced with `***`) and contains everything above in one file.
