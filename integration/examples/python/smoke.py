"""Smoke test: S3 put+get and a DynamoDB round-trip against aws-local-lab.

Exits 0 on success, non-zero on any failure. Safe to run repeatedly.
"""
from __future__ import annotations

import sys
import time
import uuid

from botocore.exceptions import ClientError

from client import client

BUCKET = "integration-smoke-py"
TABLE = "integration-smoke-py"


def wait_for_edge(timeout: int = 60) -> None:
    s3 = client("s3")
    deadline = time.time() + timeout
    while True:
        try:
            s3.list_buckets()
            return
        except Exception as exc:  # noqa: BLE001
            if time.time() > deadline:
                raise
            print(f"waiting for lab edge... ({exc})")
            time.sleep(2)


def ensure_bucket(s3) -> None:
    try:
        s3.head_bucket(Bucket=BUCKET)
    except ClientError:
        s3.create_bucket(Bucket=BUCKET)


def ensure_table(ddb) -> None:
    existing = ddb.list_tables()["TableNames"]
    if TABLE not in existing:
        ddb.create_table(
            TableName=TABLE,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        ddb.get_waiter("table_exists").wait(TableName=TABLE)


def main() -> int:
    wait_for_edge()
    s3 = client("s3")
    ddb = client("dynamodb")

    ensure_bucket(s3)
    ensure_table(ddb)

    key = f"obj-{uuid.uuid4()}"
    body = f"hello-{uuid.uuid4()}".encode()
    s3.put_object(Bucket=BUCKET, Key=key, Body=body)
    got = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    assert got == body, f"S3 body mismatch: {got!r} != {body!r}"
    print(f"[python] S3 put/get OK  s3://{BUCKET}/{key} ({len(body)} bytes)")

    item_id = str(uuid.uuid4())
    ddb.put_item(TableName=TABLE, Item={"id": {"S": item_id}, "v": {"S": "round-trip"}})
    read = ddb.get_item(TableName=TABLE, Key={"id": {"S": item_id}})["Item"]
    assert read["v"]["S"] == "round-trip", f"DynamoDB mismatch: {read!r}"
    print(f"[python] DynamoDB round-trip OK  {TABLE}/{item_id}")

    print("[python] SMOKE PASS")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"[python] SMOKE FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
