// Smoke test: S3 put+get and a DynamoDB round-trip against aws-local-lab.
// Exits 0 on success, non-zero on failure. Safe to run repeatedly.
import { randomUUID } from "node:crypto";
import {
  CreateBucketCommand,
  GetObjectCommand,
  HeadBucketCommand,
  PutObjectCommand,
} from "@aws-sdk/client-s3";
import {
  CreateTableCommand,
  DescribeTableCommand,
  GetItemCommand,
  ListTablesCommand,
  PutItemCommand,
} from "@aws-sdk/client-dynamodb";
import { s3 as makeS3, dynamodb as makeDdb } from "./client.mjs";

const BUCKET = "integration-smoke-node";
const TABLE = "integration-smoke-node";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForEdge(ddb, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      await ddb.send(new ListTablesCommand({}));
      return;
    } catch (err) {
      if (Date.now() > deadline) throw err;
      console.log(`waiting for lab edge... (${err.name})`);
      await sleep(2000);
    }
  }
}

async function ensureBucket(s3) {
  try {
    await s3.send(new HeadBucketCommand({ Bucket: BUCKET }));
  } catch {
    await s3.send(new CreateBucketCommand({ Bucket: BUCKET }));
  }
}

async function ensureTable(ddb) {
  const { TableNames } = await ddb.send(new ListTablesCommand({}));
  if (TableNames.includes(TABLE)) return;
  await ddb.send(
    new CreateTableCommand({
      TableName: TABLE,
      KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
      AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
      BillingMode: "PAY_PER_REQUEST",
    }),
  );
  for (let i = 0; i < 30; i++) {
    const { Table } = await ddb.send(new DescribeTableCommand({ TableName: TABLE }));
    if (Table.TableStatus === "ACTIVE") return;
    await sleep(1000);
  }
}

async function streamToString(stream) {
  const chunks = [];
  for await (const chunk of stream) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

async function main() {
  const s3 = makeS3();
  const ddb = makeDdb();

  await waitForEdge(ddb);
  await ensureBucket(s3);
  await ensureTable(ddb);

  const key = `obj-${randomUUID()}`;
  const body = `hello-${randomUUID()}`;
  await s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: key, Body: body }));
  const got = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: key }));
  const text = await streamToString(got.Body);
  if (text !== body) throw new Error(`S3 body mismatch: ${text} != ${body}`);
  console.log(`[node] S3 put/get OK  s3://${BUCKET}/${key} (${body.length} bytes)`);

  const id = randomUUID();
  await ddb.send(
    new PutItemCommand({ TableName: TABLE, Item: { id: { S: id }, v: { S: "round-trip" } } }),
  );
  const read = await ddb.send(
    new GetItemCommand({ TableName: TABLE, Key: { id: { S: id } } }),
  );
  if (read.Item?.v?.S !== "round-trip") throw new Error(`DynamoDB mismatch: ${JSON.stringify(read.Item)}`);
  console.log(`[node] DynamoDB round-trip OK  ${TABLE}/${id}`);

  console.log("[node] SMOKE PASS");
}

main().catch((err) => {
  console.error(`[node] SMOKE FAIL: ${err.message}`);
  process.exit(1);
});
