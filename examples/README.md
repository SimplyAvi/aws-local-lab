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
