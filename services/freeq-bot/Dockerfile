FROM node:24-alpine

# su-exec drops privileges in the entrypoint, after it has fixed ownership of
# the mounted volume (Fly mounts volumes root-owned regardless of USER).
RUN apk add --no-cache git su-exec

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY tsconfig.json ./
COPY src ./src
COPY docker-entrypoint.sh /usr/local/bin/

# The did:key seed lives here — mount a volume or the bot gets a new identity
# (and a new DID) every time the container is replaced.
ENV FREEQ_STATE_DIR=/data
VOLUME /data

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["npm", "start"]
