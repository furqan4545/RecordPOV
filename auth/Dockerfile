FROM node:22-bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
COPY test ./test
RUN npm test && npm run build && npm prune --omit=dev --ignore-scripts --no-audit

FROM node:22-bookworm-slim
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8789 AUTH_DATABASE_PATH=/data/auth.sqlite NODE_OPTIONS=--max-old-space-size=256
RUN groupadd --gid 10003 recordpov-auth && useradd --uid 10003 --gid 10003 --no-create-home --shell /usr/sbin/nologin recordpov-auth && mkdir /data && chown 10003:10003 /data && chmod 0700 /data
WORKDIR /app
COPY --from=build --chown=10003:10003 /app/node_modules ./node_modules
COPY --from=build --chown=10003:10003 /app/dist/src ./dist/src
COPY --chown=10003:10003 package.json ./
USER 10003:10003
CMD ["node", "dist/src/index.js"]
