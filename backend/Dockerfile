# ---- Stage 1: install semua dependency (termasuk devDependencies untuk lint & test)
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

# ---- Stage 2: quality gate CI (lint + unit test). Build gagal jika ada yang tidak lulus.
FROM deps AS test
COPY . .
RUN npm run lint && npm test

# ---- Stage 3: image produksi (hanya dependency runtime, user non-root)
FROM node:22-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY src/ ./src/
USER node
EXPOSE 3000
CMD ["node", "src/server.js"]
