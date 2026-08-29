// AWS SDK v3 client factory for the aws-local-lab.
//
// Reads AWS_ENDPOINT_URL (set by integration/aws-local-env.sh or compose env);
// falls back to the in-network service name so it works as a container joined
// to the aws-local-lab network.
import { S3Client } from "@aws-sdk/client-s3";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";

const DEFAULT_ENDPOINT = "http://aws-local-lab:4566";

export function endpoint() {
  return process.env.AWS_ENDPOINT_URL || DEFAULT_ENDPOINT;
}

export function region() {
  return process.env.AWS_DEFAULT_REGION || process.env.AWS_REGION || "us-east-1";
}

const common = () => ({
  endpoint: endpoint(),
  region: region(),
  credentials: {
    accessKeyId: process.env.AWS_ACCESS_KEY_ID || "test",
    secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY || "test",
  },
});

// forcePathStyle is required for LocalStack S3.
export const s3 = () => new S3Client({ ...common(), forcePathStyle: true });
export const dynamodb = () => new DynamoDBClient(common());
