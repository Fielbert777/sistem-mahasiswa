# ---- Stage 1: quality gate CI (validasi HTML + cek sintaks JavaScript)
FROM node:22-alpine AS lint
WORKDIR /src
COPY public/ ./public/
RUN npx --yes htmlhint@1.1.4 "public/**/*.html" && node --check public/js/app.js

# ---- Stage 2: image produksi (Nginx menyajikan file statis + reverse proxy /api)
FROM nginx:1.27-alpine AS runtime
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/
EXPOSE 80
