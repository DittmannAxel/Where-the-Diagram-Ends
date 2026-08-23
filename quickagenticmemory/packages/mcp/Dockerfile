# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

FROM node:22.22.3-bookworm-slim@sha256:e21fc383b50d5347dc7a9f1cae45b8f4e2f0d39f7ade28e4eef7d2934522b752 AS build

WORKDIR /build/quickagenticmemory/packages/mcp

COPY quickagenticmemory/packages/mcp/package.json quickagenticmemory/packages/mcp/package-lock.json ./
RUN npm ci --ignore-scripts

COPY quickagenticmemory/packages/mcp/tsconfig.json ./tsconfig.json
COPY quickagenticmemory/packages/mcp/src ./src
COPY quickagenticmemory/contracts/qam-graph-1.0.ts ./canonical-qam-graph-1.0.ts
RUN node -e "const fs=require('node:fs');if(fs.readFileSync('canonical-qam-graph-1.0.ts','utf8')!==fs.readFileSync('src/qam-graph-contract.ts','utf8'))throw new Error('MCP qam-graph/1.0 contract copy is stale')" \
    && npm run build \
    && npm prune --omit=dev --ignore-scripts \
    && npm cache clean --force

FROM node:22.22.3-bookworm-slim@sha256:e21fc383b50d5347dc7a9f1cae45b8f4e2f0d39f7ade28e4eef7d2934522b752 AS runtime

ENV NODE_ENV=production \
    QAM_TRANSPORT=http \
    QAM_HTTP_HOST=0.0.0.0 \
    QAM_HTTP_PORT=3000 \
    PORT=3000

WORKDIR /app

COPY --from=build --chown=node:node /build/quickagenticmemory/packages/mcp/package.json ./package.json
COPY --from=build --chown=node:node /build/quickagenticmemory/packages/mcp/node_modules ./node_modules
COPY --from=build --chown=node:node /build/quickagenticmemory/packages/mcp/dist ./dist

USER node
EXPOSE 3000
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3000/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"]

CMD ["node", "dist/cli.js", "--transport=http"]
