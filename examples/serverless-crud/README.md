# serverless-crud - end-to-end sample app (FR-3)

A small but real multi-tier serverless app, deployed to the local lab and tested
end to end. It is meant to be **copied**: take `examples/serverless-crud/`, rename
`notes` to your resource, and adapt the handlers. The seams you will touch are
commented in every file.

## Architecture

```
                 ┌─────────────────────────────────────────────┐
                 │                  the lab                     │
   HTTP          │                                              │
  client ──────► │  API Gateway (REST, {proxy+} ANY)            │
                 │        │                                     │
                 │        ▼                                     │
                 │  Lambda  notes-api  ──put/get/scan/delete──►  DynamoDB  (notes)
                 │        │                                     │
                 │        ├── generate_presigned_url ─────────►  S3  (notes-uploads)
                 │        │                                     │
                 │        └── send_message ─────────────────►   SQS  (notes-events)
                 │                                              │        │
                 │                                              │        ▼  event source mapping
                 │  Lambda  notes-worker  ◄─────────────────────┘   (batch of messages)
                 │        │                                     │
                 │        ├── head_object ──────────────────►   S3  (notes-uploads)
                 │        └── update_item  (processed=true) ──►  DynamoDB  (notes)
                 └─────────────────────────────────────────────┘
```

Request path: `API Gateway -> Lambda -> DynamoDB`.
Event path: `Lambda -> SQS -> Lambda worker -> DynamoDB` (async "process upload").

### Routes (`notes-api`)

| Method | Path                     | Does                                             |
|--------|--------------------------|-------------------------------------------------|
| POST   | `/notes`                 | create a note `{title, body}` -> `201 {id,...}` |
| GET    | `/notes`                 | list all notes                                  |
| GET    | `/notes/{id}`            | fetch one, `404` if gone                        |
| DELETE | `/notes/{id}`            | delete one -> `204`                             |
| POST   | `/notes/{id}/attach`     | presign an S3 upload + enqueue a worker job -> `202 {uploadUrl,key}` |

## Commands

```bash
make up NO_TOKEN=1        # bring the lab up (no-token LocalStack image)
make sample-deploy        # create all resources, writes .stack.env
make sample-test          # end-to-end regression check (non-zero exit on any failure)
make sample-destroy       # tear it all down
```

If port 4566 is already taken (another lab instance), pass `EDGE_PORT` to every
target - the scripts are port-agnostic and read `LAB_ENDPOINT` / `EDGE_PORT`:

```bash
make up NO_TOKEN=1 EDGE_PORT=4567
make sample-deploy EDGE_PORT=4567
make sample-test    EDGE_PORT=4567
```

## Why a deploy script, not Terraform

The `lab-terraform` track lands in parallel, so this track must stand alone. The
whole stack is ~8 resources wired once; a flat script over the same `bin/awslocal`
wrapper the rest of the lab uses is the simplest end-to-end path and doubles as a
readable catalogue of every API call involved. Move to Terraform if the stack grows
past what one script explains clearly.

## What the e2e test asserts

`test/e2e_test.py` (stdlib only, no pip installs) runs against a freshly deployed
stack and asserts **behaviour**, not just HTTP 200s:

1. create -> `201`, response carries an `id`, `processed` is `false`
2. read back -> `title` / `body` round-trip
3. list -> the new note is present
4. `attach` -> `202` with a usable presigned URL
5. presigned `PUT` uploads bytes straight to S3 -> `200`
6. **the SQS worker actually ran**: poll until the note flips to `processed=true`
   and the worker wrote back the S3 object key and its exact byte size
7. delete -> `204`
8. fetch the deleted note -> `404`

## LocalStack-specific quirks (honest fidelity, NFR-8)

- **REST API URL format.** LocalStack serves deployed REST APIs at
  `http://localhost:<edge>/restapis/<api-id>/<stage>/_user_request_/<path>` - the
  `_user_request_` segment is the magic marker, there is no custom domain. The id
  is generated at deploy time; `deploy.sh` writes it to `.stack.env`.
- **Cross-container endpoint.** Code running *inside* a Lambda container cannot
  reach the edge on `localhost` (that is the lambda itself). LocalStack's internal
  DNS resolves `localhost.localstack.cloud:4566` to the edge from inside the
  container, so `deploy.sh` sets `AWS_ENDPOINT_URL` to that. On real AWS you leave
  it unset.
- **Presigned URLs are signed against that internal endpoint.** A client on the
  host must swap the host:port back to the lab's real edge before using the URL.
  The signature covers the path + query, not the netloc, so the rewrite is safe -
  see the rewrite in `e2e_test.py` step 5.
- **Lambda cold start.** First invocation pulls/builds the runtime image; the test
  uses generous timeouts (`wait function-active-v2`, a 45s poll for the worker).
- **IAM is not enforced.** The Lambda execution role
  (`arn:aws:iam::000000000000:role/lambda-role`) is required by the API but never
  checked. Account id is always `000000000000`.
- **DynamoDB reserved words.** `processed`, `attachment`, `size` are reserved;
  update expressions must alias them via `ExpressionAttributeNames`
  (`worker_handler.py`).

## Files

| File | Role |
|------|------|
| `src/api_handler.py`    | HTTP API Lambda - routing + CRUD + presign + enqueue |
| `src/worker_handler.py` | SQS worker Lambda - the async event path |
| `deploy.sh`             | create every resource (idempotent-ish; run destroy first) |
| `destroy.sh`            | tear it all down; safe to run repeatedly |
| `test/e2e_test.py`      | the regression check |
| `.stack.env`            | generated by `deploy.sh`, consumed by test + destroy (gitignored) |
