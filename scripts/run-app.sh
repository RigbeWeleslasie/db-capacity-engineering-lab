#!/usr/bin/env bash
# =============================================================================
# scripts/run-app.sh
# -----------------------------------------------------------------------------
# The REAL runtime target for this lab, per the trainer's clarification:
# LocalStack's free Hobby tier gives Docker-backed EC2 only as a *mock* --
# RunInstances returns "running," but there's no backing container, no
# ec2_vm_manager:docker tag, and describe-images --owners self is empty.
# Real Docker-backed EC2 (the mode that boots user-data and is curl-able) is
# a paid Base-tier-and-up feature. So: `aws_instance.app` is an IaC-only
# deliverable here -- write it, `tflocal apply` it (the mock accepts it,
# shows in state/plan), but it never actually runs the service.
#
# THIS script is what /healthz, /readyz, `make verify`, and the incident
# replay actually target: the same app image, run as a plain container,
# wired to the SAME real dependencies the (mock) EC2 instance's user-data
# would have wired it to -- real Secrets Manager (via a real `tflocal
# apply` of modules/data), real Aiven MySQL, no `if (isLocalStack)` branch
# in the app. Same discipline as user-data.sh.tftpl, just run directly
# instead of inside an instance LocalStack can't actually boot.
#
# Prereqs:
#   - LocalStack running (SERVICES must include secretsmanager) with
#     LOCALSTACK_AUTH_TOKEN exported.
#   - `tflocal apply` already run against terraform/ so module.data's
#     secret genuinely exists (this script does NOT apply Terraform itself
#     -- see Makefile's `plan`/`apply` targets for that).
#   - The app image built (docker build -t <tag> api/, or use CI's
#     localstack-ec2/<name>:ami-<sha12> tag).
#
# Usage:
#   ./scripts/run-app.sh <image-tag> <secret-arn> [ca-cert-path]
#
# Example:
#   ./scripts/run-app.sh db-capacity-engineering-lab-capacity-api:latest \
#     "arn:aws:secretsmanager:us-east-1:000000000000:secret:regional-health/db-XXXXXX" \
#     ~/.aiven/ca.pem
# =============================================================================
set -euo pipefail

IMAGE_TAG="${1:?Usage: $0 <image-tag> <secret-arn> [ca-cert-path]}"
SECRET_ARN="${2:?Usage: $0 <image-tag> <secret-arn> [ca-cert-path]}"
CA_CERT_PATH="${3:-$HOME/.aiven/ca.pem}"

CONTAINER_NAME="${CONTAINER_NAME:-capacity-api-runtime}"
APP_PORT="${APP_PORT:-3000}"
AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
AWS_REGION="${AWS_REGION:-us-east-1}"

echo ">> Stopping any previous run of ${CONTAINER_NAME}..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

# --network host, not a container-name/bridge lookup: on the default bridge
# network, "localhost:4566" inside the app container means the container's
# OWN loopback, not the host running LocalStack -- confirmed the hard way,
# not assumed (a bridge-network attempt reached nothing until this). Host
# networking sidesteps that entirely: AWS_ENDPOINT_URL=http://localhost:4566
# genuinely reaches LocalStack's published port, and the app's own port
# needs no -p mapping since it's already bound directly on the host. This
# assignment is Linux-only anyway (LocalStack's own EC2 model requires it),
# so --network host has no macOS Docker Desktop caveat to worry about here.
RUN_ARGS=(
  --rm -d --name "${CONTAINER_NAME}"
  --network host
  -e "PORT=${APP_PORT}"
  -e "DB_SECRET_ARN=${SECRET_ARN}"
  -e "AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL}"
  -e "AWS_REGION=${AWS_REGION}"
  -e "AWS_ACCESS_KEY_ID=test"
  -e "AWS_SECRET_ACCESS_KEY=test"
  -e "MONGO_URI=mongodb://mongo-db:27017"
)

# The Aiven CA cert is public (not secret) -- see modules/data's README and
# modules/service's db_ca_cert variable for the same reasoning. Mount it in
# read-only and point DB_CA_CERT_PATH at the mounted path, exactly matching
# what user-data.sh.tftpl does for a real EC2 instance.
if [ -f "${CA_CERT_PATH}" ]; then
  RUN_ARGS+=(-v "${CA_CERT_PATH}:/etc/app/db-ca.pem:ro" -e "DB_CA_CERT_PATH=/etc/app/db-ca.pem")
else
  echo ">> WARNING: CA cert not found at ${CA_CERT_PATH} -- running without TLS verification configured." >&2
fi

echo ">> Starting ${CONTAINER_NAME} from ${IMAGE_TAG} ..."
docker run "${RUN_ARGS[@]}" "${IMAGE_TAG}"

echo ">> Waiting for readiness..."
for _ in $(seq 1 30); do
  if curl -sf "http://localhost:${APP_PORT}/readyz" >/dev/null 2>&1; then
    echo ">> Ready. /healthz and /readyz both reachable on :${APP_PORT}."
    curl -s "http://localhost:${APP_PORT}/debug/secret-source"
    echo
    exit 0
  fi
  sleep 2
done

echo ">> FAILED to reach readiness within 60s. Recent logs:" >&2
docker logs "${CONTAINER_NAME}" --tail 30 >&2
exit 1
