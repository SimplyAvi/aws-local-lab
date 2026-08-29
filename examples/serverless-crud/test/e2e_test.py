#!/usr/bin/env python3
"""End-to-end regression check for the serverless-crud sample.

Runs against a freshly deployed stack (deploy.sh writes ../.stack.env) and walks
the whole path a real client would:

    create -> read back -> list -> presign -> upload to S3 -> (async worker) ->
    assert the note was processed -> delete -> assert gone

Every step asserts on behaviour, not just status codes - e.g. it fails unless the
SQS worker actually ran and wrote the attachment size back into DynamoDB.

Pure stdlib (urllib) so it needs no pip installs. Non-zero exit on any failure.
Run via `make sample-test`.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit, urlunsplit

HERE = os.path.dirname(os.path.abspath(__file__))
STACK_ENV = os.path.join(HERE, "..", ".stack.env")


def load_stack():
    if not os.path.exists(STACK_ENV):
        sys.exit("no .stack.env - run `make sample-deploy` first")
    cfg = {}
    with open(STACK_ENV) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k] = v
    return cfg


def req(method, url, body=None, headers=None, raw=False):
    data = None
    hdrs = headers or {}
    if body is not None and not raw:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    elif raw and body is not None:
        data = body
    request = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(request, timeout=30) as resp:
            payload = resp.read()
            return resp.status, payload
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def as_json(payload):
    return json.loads(payload) if payload else {}


PASS = 0


def check(label, cond):
    global PASS
    mark = "ok  " if cond else "FAIL"
    print(f"  [{mark}] {label}")
    if cond:
        PASS += 1
    else:
        raise AssertionError(label)


def main():
    cfg = load_stack()
    base = cfg["API_URL"] + "/notes"
    print(f"API base: {base}")

    # 1. create
    status, payload = req("POST", base, {"title": "buy milk", "body": "2%"})
    note = as_json(payload)
    check("POST /notes -> 201", status == 201)
    check("response has id", bool(note.get("id")))
    check("processed starts false", note.get("processed") is False)
    note_id = note["id"]

    # 2. read back
    status, payload = req("GET", f"{base}/{note_id}")
    got = as_json(payload)
    check("GET /notes/{id} -> 200", status == 200)
    check("title round-trips", got.get("title") == "buy milk")
    check("body round-trips", got.get("body") == "2%")

    # 3. list
    status, payload = req("GET", base)
    listing = as_json(payload)
    check("GET /notes -> 200", status == 200)
    check("new note is in the list", any(n["id"] == note_id for n in listing.get("notes", [])))

    # 4. presign + enqueue
    status, payload = req("POST", f"{base}/{note_id}/attach")
    attach = as_json(payload)
    check("POST /notes/{id}/attach -> 202", status == 202)
    check("got a presigned uploadUrl", attach.get("uploadUrl", "").startswith("http"))
    key = attach["key"]

    # 5. upload the object straight to S3 with the presigned URL.
    # LocalStack quirk: the URL is signed inside the Lambda container against the
    # cross-container endpoint (localhost.localstack.cloud:4566). From the host we
    # swap in the lab's real host:port - the signature covers the path + query,
    # not the netloc, so this is safe.
    lab = urlsplit(cfg["LAB_ENDPOINT"])
    up = urlsplit(attach["uploadUrl"])
    upload_url = urlunsplit((lab.scheme, lab.netloc, up.path, up.query, ""))
    blob = b"hello from the e2e test " * 10
    status, _ = req("PUT", upload_url, body=blob, raw=True)
    check("presigned PUT to S3 -> 200", status == 200)

    # 6. the async worker should pick the SQS message up and mark the note
    deadline = time.time() + 45
    processed = None
    while time.time() < deadline:
        _, payload = req("GET", f"{base}/{note_id}")
        processed = as_json(payload)
        if processed.get("processed"):
            break
        time.sleep(2)
    check("SQS worker marked note processed", processed.get("processed") is True)
    check("worker recorded the attachment key", processed.get("attachment") == key)
    check(
        "worker recorded correct object size",
        str(processed.get("attachmentSize")) == str(len(blob)),
    )

    # 7. delete
    status, _ = req("DELETE", f"{base}/{note_id}")
    check("DELETE /notes/{id} -> 204", status == 204)

    # 8. gone
    status, _ = req("GET", f"{base}/{note_id}")
    check("GET deleted note -> 404", status == 404)

    print(f"\n{PASS} checks passed")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as exc:
        print(f"\nE2E FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
