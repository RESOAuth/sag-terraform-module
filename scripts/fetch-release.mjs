#!/usr/bin/env node
// Resolve a smart-access-gateway version and stage its source for packaging.
//
// Invoked as a Terraform `data "external"` source from modules/aws/release.tf
// and modules/cloudflare/main.tf, so that `terraform plan` reports the tag and
// commit it resolved rather than that happening in a build step outside
// Terraform's own graph. Reads a JSON query on stdin, writes a flat JSON object
// of strings on stdout, exactly as the external provider's protocol requires.
//
// Deliberately dependency-free: this runs from inside a Terraform module that
// may have been fetched straight from git by `terraform init`, where there is
// no `npm install` step and no node_modules to rely on. GitHub is reached with
// fetch(), and extraction shells out to the system tar.
//
// Nothing here handles a secret. See scripts/sag-secrets.mjs for the one
// script that does.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join, resolve as resolvePath } from 'node:path';

const REPO = process.env.SAG_REPO || 'RESOAuth/smart-access-gateway';

// One fixed timestamp and one fixed mode for every staged file. `archive_file`
// carries each file's mtime *and* its permission bits into the zip entry, so
// without this the archive hash changes on every re-stage and Terraform reports
// a code update it cannot explain for source that did not change.
//
// The mode matters as much as the mtime and is easier to miss, because it only
// bites across machines: whoever staged the source last decides the bits, so a
// laptop with umask 002 writes 0664 into the zip and a CI runner with umask 022
// writes 0644, and the same commit hashes differently on each. That is a
// permanent disagreement between a local apply and a pipeline apply rather than
// a diff that settles, so the two would take turns rewriting the function.
const EPOCH = new Date('1980-01-01T00:00:00Z');
const FILE_MODE = 0o644;
const DIR_MODE = 0o755;

function fail(message) {
  process.stderr.write(`fetch-release: ${message}\n`);
  process.exit(1);
}

function cacheRoot() {
  const base = process.env.SAG_IAC_CACHE_DIR
    || (process.env.XDG_CACHE_HOME ? join(process.env.XDG_CACHE_HOME, 'sag') : null)
    || (homedir() ? join(homedir(), '.cache', 'sag') : join(tmpdir(), 'sag'));
  return join(base, 'releases');
}

async function readQuery() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString('utf8').trim();
  if (!text) fail('no query on stdin; this script is invoked by Terraform, not by hand');
  try {
    return JSON.parse(text);
  } catch (err) {
    fail(`query is not JSON: ${err.message}`);
  }
}

// --- GitHub -----------------------------------------------------------------

async function github(path) {
  const headers = { 'user-agent': 'sag', accept: 'application/vnd.github+json' };
  // Unauthenticated is 60 requests/hour per IP, which is tight for a CI job
  // planning many domains in one go. A token is optional and costs nothing
  // when absent.
  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (token) headers.authorization = `Bearer ${token}`;

  const res = await fetch(`https://api.github.com/repos/${REPO}${path}`, { headers });
  if (res.status === 403 && /rate limit/i.test(await res.clone().text())) {
    fail('GitHub API rate limit reached for this IP. Set GITHUB_TOKEN in the environment to raise it from 60 to 5,000 requests/hour.');
  }
  return res;
}

async function describeAvailable() {
  const res = await github('/releases?per_page=10');
  if (!res.ok) return 'Pin an explicit tag with sag_version.';
  const releases = await res.json();
  if (!releases.length) return 'It has no releases at all yet.';
  const tags = releases.map((r) => `${r.tag_name}${r.prerelease ? ' (pre-release)' : ''}${r.draft ? ' (draft)' : ''}`);
  return `Pin one explicitly with sag_version: ${tags.join(', ')}.`;
}

async function resolveRemote(version) {
  if (version === 'bleeding-edge') {
    const res = await github('/branches/main');
    if (!res.ok) fail(`${REPO} has no main branch for "bleeding-edge" to resolve to (HTTP ${res.status}).`);
    const branch = await res.json();
    const commit = branch.commit.sha;
    return {
      tag: 'bleeding-edge',
      name: 'main',
      commit: commit.slice(0, 12),
      // The commit archive rather than the moving branch archive: main is
      // resolved once, and this is exactly the code reported below.
      tarball: `https://github.com/${REPO}/archive/${commit}.tar.gz`,
      source: `github:${REPO}@${commit.slice(0, 12)}`,
    };
  }

  const res = await github(version === 'latest' ? '/releases/latest' : `/releases/tags/${encodeURIComponent(version)}`);
  if (res.status === 404) {
    fail(
      version === 'latest'
        ? `${REPO} has no release that "latest" can resolve to. GitHub excludes pre-releases and drafts from "latest", so this also happens when every release so far is one of those: ${await describeAvailable()}`
        : `${REPO} has no release tagged ${version}. ${await describeAvailable()}`,
    );
  }
  if (!res.ok) fail(`could not resolve version "${version}": HTTP ${res.status}`);
  const release = await res.json();

  // Reported so a CI log shows which commit actually went out, which matters
  // most for an instance left on `latest`. Not worth failing over on its own.
  let commit = 'unknown';
  const ref = await github(`/commits/${encodeURIComponent(release.tag_name)}`);
  if (ref.ok) commit = (await ref.json()).sha.slice(0, 12);

  return {
    tag: release.tag_name,
    name: release.name || release.tag_name,
    commit,
    tarball: release.tarball_url,
    source: `github:${REPO}@${release.tag_name}`,
  };
}

// --- a local checkout -------------------------------------------------------

function gitDescribe(dir) {
  try {
    const head = execFileSync('git', ['-C', dir, 'rev-parse', '--short=12', 'HEAD'], { encoding: 'utf8' }).trim();
    const status = execFileSync('git', ['-C', dir, 'status', '--porcelain'], { encoding: 'utf8' }).trim();
    return { head, dirty: status.length > 0 };
  } catch {
    return { head: 'unknown', dirty: true };
  }
}

/**
 * A content fingerprint of exactly the paths that get packaged, so repeated
 * plans against an unchanged working tree hit the same cache entry and produce
 * the same archive - a dirty tree has no commit that could serve as a key.
 */
function fingerprint(root, include) {
  const hash = createHash('sha256');
  for (const item of include) {
    for (const file of walk(join(root, item), root)) {
      const info = statSync(file.full);
      hash.update(`${file.name}\0${info.size}\0${Math.floor(info.mtimeMs)}\n`);
    }
  }
  return hash.digest('hex').slice(0, 20);
}

function* walk(path, base) {
  const info = statSync(path);
  if (info.isFile()) {
    yield { full: path, name: path.slice(base.length + 1) };
    return;
  }
  for (const entry of readdirSync(path, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    if (entry.isDirectory() || entry.isFile()) yield* walk(join(path, entry.name), base);
  }
}

// --- staging ----------------------------------------------------------------

function normaliseMetadata(path) {
  const info = statSync(path);
  if (info.isDirectory()) {
    for (const entry of readdirSync(path, { withFileTypes: true })) normaliseMetadata(join(path, entry.name));
  }
  // Mode before mtime: chmod updates ctime, not mtime, but doing it the other
  // way round invites somebody to add a write here later and undo the epoch.
  chmodSync(path, info.isDirectory() ? DIR_MODE : FILE_MODE);
  utimesSync(path, EPOCH, EPOCH);
}

function stage(sourceRoot, packageDir, include) {
  rmSync(packageDir, { recursive: true, force: true });
  mkdirSync(packageDir, { recursive: true });
  for (const item of include) {
    const from = join(sourceRoot, item);
    if (!existsSync(from)) {
      fail(`the resolved source has no ${item}; this is not a smart-access-gateway tree`);
    }
    cpSync(from, join(packageDir, item), { recursive: true });
  }
  normaliseMetadata(packageDir);
}

async function download(url, into) {
  mkdirSync(into, { recursive: true });
  const res = await fetch(url, { headers: { 'user-agent': 'sag' }, redirect: 'follow' });
  if (!res.ok) fail(`could not download ${url}: HTTP ${res.status}`);
  // --strip-components=1 drops GitHub's `<owner>-<repo>-<sha>/` wrapper, so
  // the extracted tree matches the repository layout exactly.
  execFileSync('tar', ['-xz', '--strip-components=1', '-C', into], {
    input: Buffer.from(await res.arrayBuffer()),
    maxBuffer: 512 * 1024 * 1024,
  });
}

// --- main -------------------------------------------------------------------

const query = await readQuery();
const version = String(query.version || 'latest');
const include = String(query.include || 'package.json,src,adapters')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

let resolved;
let key;
let localRoot = null;

if (version.startsWith('file:')) {
  localRoot = resolvePath(version.slice('file:'.length));
  if (!existsSync(localRoot)) fail(`no such directory: ${localRoot}`);
  const git = gitDescribe(localRoot);
  key = `local-${fingerprint(localRoot, include)}`;
  resolved = {
    tag: `file:${git.head}${git.dirty ? '-dirty' : ''}`,
    name: localRoot,
    commit: git.head,
    source: `file:${localRoot}@${git.head}${git.dirty ? ' (dirty working tree)' : ''}`,
  };
} else {
  resolved = await resolveRemote(version);
  key = `${resolved.tag}-${resolved.commit}`.replace(/[^A-Za-z0-9._-]/g, '_');
}

const workDir = join(cacheRoot(), key);
const packageDir = join(workDir, 'package');
const marker = join(workDir, '.staged');
const fingerprintOf = `${include.join(',')}\n${resolved.source}`;

if (!existsSync(marker) || readFileSync(marker, 'utf8') !== fingerprintOf) {
  if (localRoot) {
    stage(localRoot, packageDir, include);
  } else {
    const extractDir = join(workDir, 'src');
    rmSync(extractDir, { recursive: true, force: true });
    await download(resolved.tarball, extractDir);
    stage(extractDir, packageDir, include);
    rmSync(extractDir, { recursive: true, force: true });
  }
  writeFileSync(marker, fingerprintOf);
}

process.stdout.write(`${JSON.stringify({
  tag: resolved.tag,
  name: resolved.name,
  commit: resolved.commit,
  source: resolved.source,
  work_dir: workDir,
  package_dir: packageDir,
  archive_path: join(workDir, 'package.zip'),
})}\n`);
