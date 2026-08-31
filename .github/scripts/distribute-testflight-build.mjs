#!/usr/bin/env node

import { sign } from 'node:crypto';

const required = [
  'APPSTORE_ISSUER_ID',
  'APPSTORE_API_KEY_ID',
  'APPSTORE_API_PRIVATE_KEY',
  'APP_BUNDLE_ID',
  'APP_MARKETING_VERSION',
  'TESTFLIGHT_GROUP_NAME',
  'CI_BUILD_NUMBER',
];

for (const name of required) {
  if (!process.env[name]) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
}

const apiBase = 'https://api.appstoreconnect.apple.com';

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

function token() {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({
    alg: 'ES256',
    kid: process.env.APPSTORE_API_KEY_ID,
    typ: 'JWT',
  }));
  const payload = base64url(JSON.stringify({
    iss: process.env.APPSTORE_ISSUER_ID,
    iat: now,
    exp: now + 10 * 60,
    aud: 'appstoreconnect-v1',
  }));
  const unsigned = `${header}.${payload}`;
  const signature = sign('sha256', Buffer.from(unsigned), {
    key: process.env.APPSTORE_API_PRIVATE_KEY.replaceAll('\\n', '\n'),
    dsaEncoding: 'ieee-p1363',
  }).toString('base64url');
  return `${unsigned}.${signature}`;
}

async function request(path, options = {}) {
  const response = await fetch(`${apiBase}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${token()}`,
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...options.headers,
    },
  });
  const text = await response.text();
  let body = {};
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = { raw: text.slice(0, 500) };
    }
  }
  if (!response.ok) {
    const details = (body.errors || [])
      .map((error) => `${error.title || 'Error'}: ${error.detail || ''}`)
      .join('; ');
    throw new Error(`App Store Connect ${options.method || 'GET'} ${path} failed (${response.status}): ${details || JSON.stringify(body)}`);
  }
  return body;
}

function oneExact(items, description, predicate) {
  const matches = items.filter(predicate);
  if (matches.length !== 1) {
    throw new Error(`Expected exactly one ${description}, found ${matches.length}`);
  }
  return matches[0];
}

const apps = await request(`/v1/apps?filter[bundleId]=${encodeURIComponent(process.env.APP_BUNDLE_ID)}&limit=200`);
const app = oneExact(
  apps.data || [],
  `app with bundle id ${process.env.APP_BUNDLE_ID}`,
  (item) => item.attributes?.bundleId === process.env.APP_BUNDLE_ID,
);

const groups = await request(`/v1/betaGroups?filter[app]=${encodeURIComponent(app.id)}&limit=200`);
const group = oneExact(
  groups.data || [],
  `internal group named ${process.env.TESTFLIGHT_GROUP_NAME}`,
  (item) => item.attributes?.name === process.env.TESTFLIGHT_GROUP_NAME
    && item.attributes?.isInternalGroup === true,
);

const versions = await request(
  `/v1/preReleaseVersions?filter[app]=${encodeURIComponent(app.id)}&filter[version]=${encodeURIComponent(process.env.APP_MARKETING_VERSION)}&filter[platform]=IOS&limit=200`,
);
const preReleaseVersion = oneExact(
  versions.data || [],
  `iOS prerelease version ${process.env.APP_MARKETING_VERSION}`,
  (item) => item.attributes?.version === process.env.APP_MARKETING_VERSION
    && item.attributes?.platform === 'IOS',
);

let build;
for (let attempt = 1; attempt <= 10; attempt += 1) {
  const builds = await request(`/v1/builds?filter[preReleaseVersion]=${encodeURIComponent(preReleaseVersion.id)}&sort=-uploadedDate&limit=50`);
  build = (builds.data || []).find(
    (item) => item.attributes?.version === process.env.CI_BUILD_NUMBER,
  );
  if (build) break;
  if (attempt < 10) {
    console.log(`Build ${process.env.CI_BUILD_NUMBER} is not queryable yet; retrying (${attempt}/10)`);
    await new Promise((resolve) => setTimeout(resolve, 30_000));
  }
}

if (!build) {
  throw new Error(`Build ${process.env.CI_BUILD_NUMBER} was uploaded but did not become queryable`);
}

const existing = await request(`/v1/betaGroups/${encodeURIComponent(group.id)}/relationships/builds?limit=200`);
if ((existing.data || []).some((item) => item.id === build.id)) {
  console.log(`Build ${process.env.CI_BUILD_NUMBER} is already available to ${process.env.TESTFLIGHT_GROUP_NAME}`);
  process.exit(0);
}

if (process.env.TESTFLIGHT_DISTRIBUTION_DRY_RUN === 'true') {
  console.log(`Dry run: build ${process.env.CI_BUILD_NUMBER} can be assigned to ${process.env.TESTFLIGHT_GROUP_NAME}`);
  process.exit(0);
}

await request(`/v1/betaGroups/${encodeURIComponent(group.id)}/relationships/builds`, {
  method: 'POST',
  body: JSON.stringify({ data: [{ type: 'builds', id: build.id }] }),
});

console.log(`Build ${process.env.CI_BUILD_NUMBER} is available to ${process.env.TESTFLIGHT_GROUP_NAME}`);
