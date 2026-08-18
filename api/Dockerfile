# Node.js API image for the Regional Health service.
FROM node:20-alpine

# The seed script (run inside this container) needs the mysql CLI.
# apk upgrade first: picks up patched OS packages within this pinned alpine
# release (e.g. libcrypto3/libssl3 CVE fixes) without bumping the base tag.
RUN apk upgrade --no-cache \
    && apk add --no-cache mysql-client bash

WORKDIR /usr/src/app

COPY package.json ./
RUN npm install --omit=dev \
    # npm's own bundled tooling (tar/glob/minimatch/sigstore/etc., never used
    # at runtime — only `node server.js` runs) carries CVEs of its own
    # (confirmed: none of these packages appear in package-lock.json, they
    # live at /usr/local/lib/node_modules/npm/node_modules/*, part of the
    # base image, not this app). Remove npm itself once install is done.
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack

COPY . .

# The seed script lives in ../data-seed and is bind-mounted at runtime by
# docker-compose to /usr/local/bin/seed.sh (it is outside this build context,
# so it cannot be COPYed here).

# DELIBERATE RED-PR CHANGE — do not merge. Drops the USER directive this
# repo already fixed once (trivy DS-0002, "Image user should not be root"),
# to prove the trivy config gate actually blocks re-introducing it, not
# just that it caught it the first time.

EXPOSE 3000

CMD ["node", "server.js"]
