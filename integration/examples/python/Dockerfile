# Proves the boto3 client factory runs containerised against the lab network.
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY client.py smoke.py ./

# Default endpoint is the in-network service name; override via AWS_ENDPOINT_URL.
ENV AWS_ENDPOINT_URL=http://aws-local-lab:4566 \
    AWS_ACCESS_KEY_ID=test \
    AWS_SECRET_ACCESS_KEY=test \
    AWS_DEFAULT_REGION=us-east-1

CMD ["python", "smoke.py"]
