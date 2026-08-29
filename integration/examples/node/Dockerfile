# Proves the AWS SDK v3 client factory runs containerised against the lab network.
FROM node:22-alpine

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY client.mjs smoke.mjs ./

ENV AWS_ENDPOINT_URL=http://aws-local-lab:4566 \
    AWS_ACCESS_KEY_ID=test \
    AWS_SECRET_ACCESS_KEY=test \
    AWS_DEFAULT_REGION=us-east-1

CMD ["node", "smoke.mjs"]
