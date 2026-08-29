// aws-local-lab :: load-harness sample service
//
// A stateless HTTP service. All state lives in Layer 1 (LocalStack S3 +
// DynamoDB) so every replica is interchangeable and the balancer can spread
// or fail over freely.
//
// Routes:
//   GET  /healthz      -> 200 once S3 + DynamoDB are reachable
//   GET  /             -> replica id + counters
//   POST /work         -> write an item to DynamoDB + an object to S3, read back
//   GET  /work/:id     -> fetch a previously written item
import http from "node:http";
import { hostname } from "node:os";
import { randomUUID } from "node:crypto";
import {
  CreateBucketCommand,
  GetObjectCommand,
  HeadBucketCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import {
  CreateTableCommand,
  DescribeTableCommand,
  GetItemCommand,
  ListTablesCommand,
  PutItemCommand,
  DynamoDBClient,
} from "@aws-sdk/client-dynamodb";

const PORT = Number(process.env.PORT || 8080);
const ENDPOINT = process.env.AWS_ENDPOINT_URL || "http://aws-local-lab:4566";
const REGION = process.env.AWS_DEFAULT_REGION || "us-east-1";
const BUCKET = process.env.LAB_BUCKET || "load-harness";
const TABLE = process.env.LAB_TABLE || "load-harness";
const REPLICA = hostname();

const creds = {
  accessKeyId: process.env.AWS_ACCESS_KEY_ID || "test",
  secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || "test",
};
const s3 = new S3Client({ endpoint: ENDPOINT, region: REGION, credentials: creds, forcePathStyle: true });
const ddb = new DynamoDBClient({ endpoint: ENDPOINT, region: REGION, credentials: creds });

let ready = false;
let served = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function ensureInfra() {
  for (let attempt = 1; ; attempt++) {
    try {
      try {
        await s3.send(new HeadBucketCommand({ Bucket: BUCKET }));
      } catch {
        await s3.send(new CreateBucketCommand({ Bucket: BUCKET }));
      }
      const { TableNames } = await ddb.send(new ListTablesCommand({}));
      if (!TableNames.includes(TABLE)) {
        await ddb
          .send(
            new CreateTableCommand({
              TableName: TABLE,
              KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
              AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
              BillingMode: "PAY_PER_REQUEST",
            }),
          )
          .catch((e) => {
            if (e.name !== "ResourceInUseException") throw e;
          });
      }
      for (let i = 0; i < 30; i++) {
        const { Table } = await ddb.send(new DescribeTableCommand({ TableName: TABLE }));
        if (Table.TableStatus === "ACTIVE") break;
        await sleep(1000);
      }
      ready = true;
      console.log(`[${REPLICA}] infra ready (bucket=${BUCKET} table=${TABLE})`);
      return;
    } catch (err) {
      console.log(`[${REPLICA}] infra not ready (attempt ${attempt}): ${err.name}`);
      await sleep(2000);
    }
  }
}

function send(res, code, body) {
  const payload = JSON.stringify({ replica: REPLICA, ...body });
  res.writeHead(code, { "content-type": "application/json" });
  res.end(payload);
}

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8");
}

async function streamToString(stream) {
  const chunks = [];
  for await (const c of stream) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8");
}

const server = http.createServer(async (req, res) => {
  served++;
  const url = new URL(req.url, "http://x");
  try {
    if (url.pathname === "/healthz") {
      return ready ? send(res, 200, { ok: true }) : send(res, 503, { ok: false });
    }
    if (url.pathname === "/" && req.method === "GET") {
      return send(res, 200, { served, ready });
    }
    if (url.pathname === "/work" && req.method === "POST") {
      const raw = await readBody(req);
      const id = randomUUID();
      const value = raw || `payload-${id}`;
      await s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: `work/${id}`, Body: value }));
      await ddb.send(
        new PutItemCommand({
          TableName: TABLE,
          Item: { id: { S: id }, value: { S: value }, replica: { S: REPLICA } },
        }),
      );
      const back = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: `work/${id}` }));
      const stored = await streamToString(back.Body);
      return send(res, 201, { id, stored, roundtrip: stored === value });
    }
    if (url.pathname.startsWith("/work/") && req.method === "GET") {
      const id = url.pathname.slice("/work/".length);
      const got = await ddb.send(new GetItemCommand({ TableName: TABLE, Key: { id: { S: id } } }));
      if (!got.Item) return send(res, 404, { id, found: false });
      return send(res, 200, { id, found: true, value: got.Item.value.S, writtenBy: got.Item.replica.S });
    }
    return send(res, 404, { error: "not found" });
  } catch (err) {
    console.error(`[${REPLICA}] ${req.method} ${req.url} -> ${err.name}: ${err.message}`);
    return send(res, 500, { error: err.name });
  }
});

server.listen(PORT, () => console.log(`[${REPLICA}] listening on :${PORT} -> ${ENDPOINT}`));
ensureInfra();
