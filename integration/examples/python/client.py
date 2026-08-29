"""boto3 client factory for the aws-local-lab.

Every client reads AWS_ENDPOINT_URL (set by integration/aws-local-env.sh or the
compose environment). Falls back to the in-network endpoint so it "just works"
when run as a container joined to the aws-local-lab network.
"""
from __future__ import annotations

import os

import boto3

DEFAULT_ENDPOINT = "http://aws-local-lab:4566"


def endpoint() -> str:
    return os.environ.get("AWS_ENDPOINT_URL") or DEFAULT_ENDPOINT


def region() -> str:
    return os.environ.get("AWS_DEFAULT_REGION") or os.environ.get("AWS_REGION") or "us-east-1"


def client(service: str):
    return boto3.client(
        service,
        endpoint_url=endpoint(),
        region_name=region(),
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
    )


def resource(service: str):
    return boto3.resource(
        service,
        endpoint_url=endpoint(),
        region_name=region(),
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
    )
