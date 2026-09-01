#!/usr/bin/env node
// The one script in this repository that ever handles a secret's plaintext.
//
// It is human-run and refuses to run without a TTY, it never runs `terraform`,
// and `terraform apply` cannot reach it. That separation is the whole point:
// `terraform apply` must not be capable of inventing SAG_SECRET, so the code
// path that can is not reachable from it. See docs/aws-secret-references.md,
// "The path a secret takes".
//
//   AWS:        ssm:PutParameter, Type SecureString, under the instance's own
//               KMS key. Terraform only ever computes the `aws:ssm:...` pointer
//               that names the parameter; it never creates the parameter, and
//               never reads its plaintext.
//   Cloudflare: `wrangler secret put`. A Workers secret is write-only at the
//               platform level - nothing, not even full account access, reads
//               one back - so there is nothing for Terraform to hold either way.
//
// Usage:
//   scripts/sag-secrets.mjs set  --instance <hostname> --name SAG_SECRET [--generate]
//                                    [--region eu-west-2] [--platform aws|cloudflare]
//                                    [--worker <script name>] [--path <ssm path>] [--key <kms alias>]
//   scripts/sag-secrets.mjs list --instance <hostname> --region eu-west-2
//
// `--generate` produces a fresh high-entropy value, writes it, and prints it
// once. Everything else prompts for a value with the terminal echo off.

import { execFileSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { createInterface } from 'node:readline';

// Secrets that must be byte-identical across every platform block of one
// instance. Generating one per block would silently produce a deployment where
// a session opened on one block cannot be read by another.
const SHARED_ACROSS_BLOCKS = new Set(['SAG_SECRET', 'SAG_SECRET_PREVIOUS', 'SUBJECT_SALT', 'HSM_SHARED_SECRET']);

function die(message) {
  process.stderr.write(`sag-secrets: ${message}\n`);
  process.exit(1);
}

function usage() {
  process.stderr.write(`Usage:
  sag-secrets.mjs set  --instance <hostname> --name <NAME> [--generate]
                           [--region <aws region>] [--platform aws|cloudflare]
                           [--worker <script name>] [--path <ssm path>] [--key <kms alias>]
  sag-secrets.mjs list --instance <hostname> --region <aws region>
`);
  process.exit(2);
}

/**
 * The same fixed-length, hash-based slug modules/sag-instance computes: the
 * lower-cased hostname's first 10 alphanumeric characters, a hyphen, and the
 * first 20 hex characters of its SHA-1.
 *
 * This is the one place the rule is written twice - Terraform cannot call into
 * JavaScript, and this script deliberately cannot call Terraform. It is not
 * left to trust: if the two ever disagreed, the parameter would land off the
 * path the Lambda's pointer names, and the `require_secrets` gate in
 * modules/aws/secrets.tf would fail the very next plan naming the secret as
 * still missing. `--path` overrides it outright.
 */
function slug(hostname) {
  const host = String(hostname || '').trim().toLowerCase();
  if (!host) die('--instance is required');
  const prefix = host.replace(/[^a-z0-9]/g, '').slice(0, 10);
  if (!prefix) die(`--instance has no alphanumeric characters: ${hostname}`);
  return `${prefix}-${createHash('sha1').update(host).digest('hex').slice(0, 20)}`;
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const flags = {};
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i];
    if (!arg.startsWith('--')) die(`unexpected argument: ${arg}`);
    const key = arg.slice(2);
    if (key === 'generate') {
      flags.generate = true;
      continue;
    }
    const value = rest[++i];
    if (value === undefined || value.startsWith('--')) die(`--${key} needs a value`);
    flags[key] = value;
  }
  return { command, flags };
}

/** Read a line with the terminal echo off, so a pasted secret is not left on screen. */
function promptHidden(question) {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    const onData = (char) => {
      // Redraw the prompt with nothing after it, whatever was typed.
      if (!['\n', '\r', ''].includes(String(char))) {
        process.stdout.write(`[2K[200D${question}`);
      }
    };
    process.stdin.on('data', onData);
    rl.question(question, (answer) => {
      process.stdin.off('data', onData);
      rl.close();
      process.stdout.write('\n');
      resolve(answer);
    });
  });
}

async function valueFor(name, flags) {
  if (flags.generate) {
    // 48 bytes, base64 - the same shape smart-access-gateway's own error
    // message recommends (`openssl rand -base64 48`).
    const value = randomBytes(48).toString('base64');
    process.stdout.write(
      `\nGenerated ${name}. Save this now - nothing can read it back:\n\n  ${value}\n\n` +
        (SHARED_ACROSS_BLOCKS.has(name)
          ? `  ${name} must be byte-identical on every platform block of this instance.\n` +
            '  Set it on the others with this exact value, not with --generate again.\n\n'
          : ''),
    );
    return value;
  }

  const value = await promptHidden(`Value for ${name} (not echoed): `);
  if (!value.trim()) die('no value given');
  return value;
}

// --- AWS --------------------------------------------------------------------

async function setAws(name, value, flags) {
  const { SSMClient, PutParameterCommand } = await import('@aws-sdk/client-ssm');
  const region = flags.region || process.env.AWS_REGION || die('--region is required for the aws platform');
  const path = flags.path || `/sag/${slug(flags.instance)}/secrets`;
  const keyId = flags.key || `alias/sag-${slug(flags.instance)}-secrets`;

  const client = new SSMClient({ region });
  await client.send(
    new PutParameterCommand({
      Name: `${path}/${name}`,
      Value: value,
      Type: 'SecureString',
      // SecureString's own encryption under this instance's customer-managed
      // key is what protects it at rest; there is no client-side kms:Encrypt
      // call, and no ciphertext for this script to hand anywhere else.
      KeyId: keyId,
      Overwrite: true,
      Tier: 'Standard',
    }),
  );
  process.stdout.write(`Set ${path}/${name} (SecureString, ${keyId}) in ${region}.\n`);
  process.stdout.write('The Lambda already carries the pointer to it; no terraform apply is needed for the value alone.\n');
}

async function listAws(flags) {
  const { SSMClient, GetParametersByPathCommand } = await import('@aws-sdk/client-ssm');
  const region = flags.region || process.env.AWS_REGION || die('--region is required for the aws platform');
  const path = flags.path || `/sag/${slug(flags.instance)}/secrets`;

  const client = new SSMClient({ region });
  const names = [];
  let token;
  do {
    const page = await client.send(
      new GetParametersByPathCommand({
        Path: path,
        Recursive: false,
        // Never true, for the same reason modules/aws/secrets.tf never sets it:
        // this command reports which secrets exist, and has no business
        // decrypting one to do that.
        WithDecryption: false,
        NextToken: token,
      }),
    );
    names.push(...(page.Parameters || []).map((p) => p.Name.split('/').pop()));
    token = page.NextToken;
  } while (token);

  process.stdout.write(`${path}/\n`);
  if (!names.length) process.stdout.write('  (nothing set yet)\n');
  for (const name of names.sort()) process.stdout.write(`  ${name}\n`);
}

// --- Cloudflare -------------------------------------------------------------

function setCloudflare(name, value, flags) {
  const worker = flags.worker || `sag-${slug(flags.instance)}`;
  try {
    execFileSync('npx', ['--yes', 'wrangler@4', 'secret', 'put', name, '--name', worker], {
      input: `${value}\n`,
      stdio: ['pipe', 'inherit', 'inherit'],
      env: { ...process.env, WRANGLER_SEND_METRICS: 'false' },
    });
  } catch (err) {
    die(`wrangler could not set ${name} on ${worker}: ${err.message}`);
  }
  process.stdout.write(`Set ${name} on Worker ${worker}. Nothing can read it back, including this script.\n`);
}

// --- main -------------------------------------------------------------------

const { command, flags } = parseArgs(process.argv.slice(2));
if (!command || !['set', 'list'].includes(command)) usage();
if (!flags.instance) usage();

// The gate that makes "apply never generates a secret" structural rather than
// a convention: no CI job, and no terraform provisioner, has a TTY.
if (!process.stdin.isTTY || !process.stdout.isTTY) {
  die(
    'this command handles secret plaintext and only runs interactively. It has no non-interactive mode on purpose: ' +
      'nothing automated, terraform included, should be able to set or invent a SAG secret.',
  );
}

const platform = flags.platform || 'aws';
if (!['aws', 'cloudflare'].includes(platform)) die('--platform must be "aws" or "cloudflare"');

if (command === 'list') {
  if (platform !== 'aws') die('list is only meaningful on aws: a Workers secret cannot be read or enumerated back.');
  await listAws(flags);
} else {
  if (!flags.name) usage();
  const value = await valueFor(flags.name, flags);
  if (platform === 'aws') await setAws(flags.name, value, flags);
  else setCloudflare(flags.name, value, flags);
}
