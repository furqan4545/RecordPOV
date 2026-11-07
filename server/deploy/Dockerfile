FROM node:22-bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY package.json package-lock.json tsconfig.json ./
RUN npm ci --ignore-scripts
COPY src ./src
COPY test ./test
COPY deploy/compose.yaml ./deploy/compose.yaml
COPY deploy/compose.caddy.yaml ./deploy/compose.caddy.yaml
RUN npm test && npm run build && npm prune --omit=dev --ignore-scripts --no-audit

FROM node:22-bookworm-slim AS runtime
ARG YTDLP_VERSION=2026.10.26
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates ffmpeg python3 python3-venv \
    && python3 -m venv /opt/yt-dlp \
    && /opt/yt-dlp/bin/pip install --no-cache-dir --disable-pip-version-check "yt-dlp[default,curl-cffi]==${YTDLP_VERSION}" \
    && /opt/yt-dlp/bin/yt-dlp --version \
    && /opt/yt-dlp/bin/python -c "import yt_dlp_ejs, curl_cffi; print('curl_cffi=' + curl_cffi.__version__)" \
    && /opt/yt-dlp/bin/yt-dlp --ignore-config --list-impersonate-targets \
    && ffmpeg -version \
    && groupadd --gid 10001 recordpov \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin recordpov \
    && install -d -o 10001 -g 10001 -m 0700 /cache /ipc \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/package.json ./package.json
COPY --from=build /build/dist/src ./dist/src
COPY --from=build /build/node_modules ./node_modules
ENV NODE_ENV=production \
    HOST=0.0.0.0 PORT=8787 CACHE_DIR=/cache \
    YTDLP_PATH=/opt/yt-dlp/bin/yt-dlp \
    FFMPEG_PATH=/usr/bin/ffmpeg FFPROBE_PATH=/usr/bin/ffprobe \
    PYTHONDONTWRITEBYTECODE=1 XDG_CACHE_HOME=/tmp/cache
USER 10001:10001
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["node", "--input-type=module", "-e", "const r = await fetch('http://127.0.0.1:8787/health', { signal: AbortSignal.timeout(3000) }); if (!r.ok) process.exit(1)"]
CMD ["node", "dist/src/index.js"]
