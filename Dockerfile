FROM node:22-alpine

# Pin the version — this tool is brand new, expect breaking changes
ARG OB_HEADLESS_VERSION=0.0.6

RUN npm install -g obsidian-headless@${OB_HEADLESS_VERSION} \
    && apk add --no-cache \
        git \
        openssh-client \
        bash \
        tzdata

# Use existing node user (UID 1000) as non-root user
RUN mkdir -p /vault && chown node:node /vault

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/backup-git.sh /usr/local/bin/backup-git.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/backup-git.sh

USER node
WORKDIR /vault

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
