"""HTTP API Lambda: CRUD for "notes" + presigned S3 upload + async enqueue.

Wired behind an API Gateway REST proxy resource ({proxy+}, ANY method) so every
route lands here and this module does the routing. Keep handlers small; this is a
template - swap the resource name, add fields, split modules as your app grows.

Seams you will customise:
  * TABLE / BUCKET / QUEUE_URL      - resource names (set by deploy.sh as env vars)
  * ROUTES                          - add your paths here
  * _create / _get / ...            - your business logic
"""

import json
import os
import time
import uuid

import boto3

TABLE = os.environ["TABLE"]
BUCKET = os.environ["BUCKET"]
QUEUE_URL = os.environ["QUEUE_URL"]

# LocalStack quirk: inside the Lambda container the edge is reachable at
# host.docker.internal / the container alias, never localhost. AWS_ENDPOINT_URL
# is set by deploy.sh; on real AWS you leave it unset and the SDK does the right
# thing.
_ENDPOINT = os.environ.get("AWS_ENDPOINT_URL") or None
_ddb = boto3.client("dynamodb", endpoint_url=_ENDPOINT)
_s3 = boto3.client("s3", endpoint_url=_ENDPOINT)
_sqs = boto3.client("sqs", endpoint_url=_ENDPOINT)


def _resp(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _item_to_note(item):
    note = {
        "id": item["id"]["S"],
        "title": item["title"]["S"],
        "body": item["body"]["S"],
        "createdAt": item["createdAt"]["S"],
        "processed": item.get("processed", {}).get("BOOL", False),
    }
    if "attachment" in item:
        note["attachment"] = item["attachment"]["S"]
    if "attachmentSize" in item:
        note["attachmentSize"] = int(item["attachmentSize"]["N"])
    return note


def _create(event):
    payload = json.loads(event.get("body") or "{}")
    if not payload.get("title"):
        return _resp(400, {"error": "title is required"})
    note_id = uuid.uuid4().hex
    item = {
        "id": {"S": note_id},
        "title": {"S": str(payload["title"])},
        "body": {"S": str(payload.get("body", ""))},
        "createdAt": {"S": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
        "processed": {"BOOL": False},
    }
    _ddb.put_item(TableName=TABLE, Item=item)
    return _resp(201, _item_to_note(item))


def _get(note_id):
    got = _ddb.get_item(TableName=TABLE, Key={"id": {"S": note_id}})
    if "Item" not in got:
        return _resp(404, {"error": "not found"})
    return _resp(200, _item_to_note(got["Item"]))


def _list():
    scanned = _ddb.scan(TableName=TABLE)
    notes = [_item_to_note(i) for i in scanned.get("Items", [])]
    return _resp(200, {"notes": notes, "count": len(notes)})


def _delete(note_id):
    got = _ddb.get_item(TableName=TABLE, Key={"id": {"S": note_id}})
    if "Item" not in got:
        return _resp(404, {"error": "not found"})
    _ddb.delete_item(TableName=TABLE, Key={"id": {"S": note_id}})
    return _resp(204, {})


def _attach(note_id):
    """Return a presigned PUT URL and enqueue an async 'process upload' job."""
    got = _ddb.get_item(TableName=TABLE, Key={"id": {"S": note_id}})
    if "Item" not in got:
        return _resp(404, {"error": "not found"})
    key = f"uploads/{note_id}/{uuid.uuid4().hex}"
    url = _s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": key},
        ExpiresIn=900,
    )
    _sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps({"noteId": note_id, "key": key}),
    )
    return _resp(202, {"uploadUrl": url, "key": key})


# path (after stripping the stage prefix) + method -> handler
def _route(method, path, path_params):
    parts = [p for p in path.strip("/").split("/") if p]
    # /notes
    if parts == ["notes"]:
        if method == "POST":
            return _create
        if method == "GET":
            return lambda e: _list()
    # /notes/{id} and /notes/{id}/attach
    if len(parts) >= 2 and parts[0] == "notes":
        note_id = path_params.get("id") or parts[1]
        if len(parts) == 2:
            if method == "GET":
                return lambda e: _get(note_id)
            if method == "DELETE":
                return lambda e: _delete(note_id)
        if len(parts) == 3 and parts[2] == "attach" and method == "POST":
            return lambda e: _attach(note_id)
    return None


def handler(event, _context):
    # REST proxy integration payload: httpMethod + path + pathParameters.
    method = event.get("httpMethod", "GET")
    path = event.get("path", "/")
    path_params = event.get("pathParameters") or {}
    try:
        route = _route(method, path, path_params)
        if route is None:
            return _resp(404, {"error": f"no route for {method} {path}"})
        result = route(event)
        return result
    except Exception as exc:  # template: surface errors as 500 JSON
        return _resp(500, {"error": type(exc).__name__, "detail": str(exc)})
