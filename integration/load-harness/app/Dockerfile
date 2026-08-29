FROM node:22-alpine

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server.mjs ./

ENV PORT=8080 \
    AWS_ENDPOINT_URL=http://aws-local-lab:4566 \
    AWS_ACCESS_KEY_ID=test \
    AWS_SECRET_ACCESS_KEY=test \
    AWS_DEFAULT_REGION=us-east-1

EXPOSE 8080
CMD ["node", "server.mjs"]
