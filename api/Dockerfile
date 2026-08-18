# Node.js API image for the Regional Health service.
FROM node:20-slim

# The seed script (run inside this container) needs the mysql CLI.
RUN apt-get update \
    && apt-get install -y --no-install-recommends default-mysql-client bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

COPY package.json ./
RUN npm install --omit=dev

COPY . .

# The seed script lives in ../data-seed and is bind-mounted at runtime by
# docker-compose to /usr/local/bin/seed.sh (it is outside this build context,
# so it cannot be COPYed here).

# trivy DS-0002: run as non-root. node:20-slim already ships a `node`
# user/group (uid/gid 1000) for exactly this — just needs ownership of the
# app dir and an explicit USER. seed.sh only runs mysql client commands over
# the network, nothing here needs root.
RUN chown -R node:node /usr/src/app
USER node

EXPOSE 3000

CMD ["node", "server.js"]
