# examples/

Seam for the `lab-sampleapp` track (FR-3): end-to-end sample applications.

## serverless-crud

A multi-tier serverless app - API Gateway -> Lambda -> DynamoDB, plus an S3
presigned-upload flow and an SQS + worker-Lambda event path - deployed to the lab
and tested end to end. Copyable template. See
[`serverless-crud/README.md`](serverless-crud/README.md).

```bash
make up NO_TOKEN=1 && make sample-deploy && make sample-test
make sample-destroy
```

## Free-tier scope

The free (community) tier is **API Gateway REST v1 only**. HTTP API v2, WebSocket
API, Cognito-authorizer, and AppSync samples require a **paid** LocalStack tier -
all return `501` on the community image. See
[`../docs/fidelity-matrix.md`](../docs/fidelity-matrix.md).
