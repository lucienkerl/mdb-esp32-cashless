FROM node:24-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
# Placeholders for build — overridden at runtime via NUXT_PUBLIC_* env vars
ENV SUPABASE_URL=http://placeholder.invalid
ENV SUPABASE_KEY=placeholder
# Version info baked into the build
ARG GIT_HASH=unknown
ARG BUILD_DATE=""
ENV GIT_HASH=${GIT_HASH}
ENV BUILD_DATE=${BUILD_DATE}
# Nuxt's client build needs more than Node's default heap on small hosts
# ("JavaScript heap out of memory" around 1.4 GB). This only raises the
# ceiling; override with --build-arg NODE_MAX_OLD_SPACE=<MB> if the host has
# less RAM (and add swap).
ARG NODE_MAX_OLD_SPACE=3072
ENV NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE}
RUN npm run build

FROM node:24-alpine
WORKDIR /app
COPY --from=builder /app/.output .output
ENV HOST=0.0.0.0
ENV PORT=3000
EXPOSE 3000
CMD ["node", ".output/server/index.mjs"]
