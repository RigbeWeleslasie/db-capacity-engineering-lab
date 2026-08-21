'use strict';

/**
 * secrets.js
 * -----------------------------------------------------------------------------
 * Resolves DB credentials at boot.
 *
 * Two modes, chosen by whether DB_SECRET_ARN is set:
 *
 *   - DB_SECRET_ARN set (deployed): call Secrets Manager's GetSecretValue
 *     ourselves, using AWS_ENDPOINT_URL/AWS_REGION exactly as modules/service's
 *     user-data exports them. The envelope's keys are frozen by
 *     MODULE-CONTRACTS.md: engine, username, password, host, port, dbname.
 *     The secret value never touches user-data, an env var set by Terraform,
 *     or git — this module is the only place it's read, and only at runtime.
 *
 *   - DB_SECRET_ARN unset (local docker-compose): fall back to the existing
 *     MYSQL_HOST/PORT/USER/PASSWORD/DATABASE env vars with their local-dev
 *     defaults, unchanged from before. Local `docker compose up` keeps
 *     working exactly as it always has — this is additive, not a rewrite of
 *     the local path.
 */

const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');

// ---------------------------------------------------------------------------
// Source tracking for /debug/secret-source and boot-log evidence (C3/C8).
// Holds ONLY the ARN + VersionId -- never the secret value, never even the
// resolved host/user. Set once, at the point loadDbConfig() actually
// resolves creds, so it reflects reality rather than being guessed at boot.
// ---------------------------------------------------------------------------
let secretSource = { arn: null, versionId: null };

function getSecretSource() {
  return { ...secretSource };
}

async function loadDbConfig() {
  const secretArn = process.env.DB_SECRET_ARN;

  if (!secretArn) {
    // Local docker-compose path — unchanged behavior.
    secretSource = { arn: 'env', versionId: 'n/a' };
    // eslint-disable-next-line no-console
    console.log(`[secrets] resolved DB config from env vars (arn=${secretSource.arn}, versionId=${secretSource.versionId}) -- no Secrets Manager call made`);
    return {
      host: process.env.MYSQL_HOST || 'mysql-db',
      port: Number(process.env.MYSQL_PORT || 3306),
      user: process.env.MYSQL_USER || 'root',
      password: process.env.MYSQL_PASSWORD || 'labpassword',
      database: process.env.MYSQL_DATABASE || 'capacity_lab',
      ssl: null,
    };
  }

  // Deployed path — resolve from Secrets Manager. AWS_ENDPOINT_URL is set by
  // modules/service's user-data on LocalStack and left unset on real AWS, so
  // this is the same client either way — no isLocalStack branch.
  const client = new SecretsManagerClient({
    region: process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || 'us-east-1',
    ...(process.env.AWS_ENDPOINT_URL ? { endpoint: process.env.AWS_ENDPOINT_URL } : {}),
  });

  const response = await client.send(new GetSecretValueCommand({ SecretId: secretArn }));
  const envelope = JSON.parse(response.SecretString);

  // ARN + VersionId only -- never engine/username/password/host/port/dbname.
  secretSource = { arn: response.ARN || secretArn, versionId: response.VersionId || 'unknown' };
  // eslint-disable-next-line no-console
  console.log(`[secrets] resolved DB config from Secrets Manager (arn=${secretSource.arn}, versionId=${secretSource.versionId})`);

  // envelope: { engine, username, password, host, port, dbname }
  const caCertPath = process.env.DB_CA_CERT_PATH;
  return {
    host: envelope.host,
    port: Number(envelope.port),
    user: envelope.username,
    password: envelope.password,
    database: envelope.dbname,
    // Aiven requires TLS. The CA cert is NOT secret (public root cert) so it
    // deliberately isn't in the envelope above — it's a plain file path set
    // by user-data, baked into the AMI, or fetched from Aiven's public URL.
    // See modules/data's README for why the cert is handled separately.
    ssl: caCertPath ? { ca: require('fs').readFileSync(caCertPath), rejectUnauthorized: true } : undefined,
  };
}

module.exports = { loadDbConfig, getSecretSource };
