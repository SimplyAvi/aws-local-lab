"""SQS worker Lambda: the async event path.

An SQS event-source mapping delivers batches of messages produced by
POST /notes/{id}/attach. For each one the worker confirms the uploaded object
exists in S3 and marks the note processed. That state change is what the e2e
test asserts on - proof the event path actually ran, not just that an HTTP call
returned 200.

Seam: replace _process_one with your real work (resize an image, send a mail,
fan out to another queue, ...). Raise to let SQS retry / dead-letter.
"""

import json
import os

import boto3

TABLE = os.environ["TABLE"]
BUCKET = os.environ["BUCKET"]

_ENDPOINT = os.environ.get("AWS_ENDPOINT_URL") or None
_ddb = boto3.client("dynamodb", endpoint_url=_ENDPOINT)
_s3 = boto3.client("s3", endpoint_url=_ENDPOINT)


def _process_one(body):
    msg = json.loads(body)
    note_id, key = msg["noteId"], msg["key"]
    # Will raise (-> SQS retry) if the client never completed the upload.
    head = _s3.head_object(Bucket=BUCKET, Key=key)
    _ddb.update_item(
        TableName=TABLE,
        Key={"id": {"S": note_id}},
        # processed / attachment / size are DynamoDB reserved words -> alias them.
        UpdateExpression="SET #p = :p, #a = :a, #s = :s",
        ExpressionAttributeNames={
            "#p": "processed",
            "#a": "attachment",
            "#s": "attachmentSize",
        },
        ExpressionAttributeValues={
            ":p": {"BOOL": True},
            ":a": {"S": key},
            ":s": {"N": str(head["ContentLength"])},
        },
    )
    print(f"processed note={note_id} key={key} size={head['ContentLength']}")


def handler(event, _context):
    records = event.get("Records", [])
    for record in records:
        _process_one(record["body"])
    return {"processed": len(records)}
