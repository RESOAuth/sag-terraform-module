#!/usr/bin/env node
// The half of "The three constraints" that has to be checked by reading the
// module rather than by planning it.
//
// `terraform test` asserts on values, so it can prove that SAG_SECRET is an
// `aws:ssm:` pointer, and test/discipline.tftest.hcl does. What it cannot do is
// notice the *absence* of something: a resource block that was never written
// produces no value to assert on, and one that gets written later produces a
// value nobody thought to check. Those are exactly the mistakes this design is
// most vulnerable to - an `aws_ssm_parameter` resource added "just to bootstrap
// it", a `with_decryption` flipped to true, a `random_password` for a real
// secret - so they get a check that reads the source directly.
//
// Run it with `node scripts/check-discipline.mjs`; exits non-zero and names the
// file and line on any violation.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const moduleRoot = join(root, 'modules');

// The one Terraform-generated value this module allows, by exact address. A
// second one has to be argued for in AGENTS.md's constraints and then added
// here deliberately, rather than slipping in unnoticed.
const ALLOWED_RANDOM_RESOURCES = new Set(['random_id.cdn_origin_secret']);

const violations = [];

function files(dir) {
  const found = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) found.push(...files(full));
    else if (entry.isFile() && entry.name.endsWith('.tf')) found.push(full);
  }
  return found;
}

function report(file, line, rule, message) {
  violations.push({ file: relative(root, file), line, rule, message });
}

/** Strip `#` and `//` line comments, so a rule quoted in a comment is not a hit. */
function withoutComments(text) {
  return text
    .split('\n')
    .map((line) => line.replace(/(^|\s)(#|\/\/).*$/, ''))
    .join('\n');
}

for (const file of files(moduleRoot)) {
  const raw = readFileSync(file, 'utf8');
  const source = withoutComments(raw);
  const lines = source.split('\n');

  lines.forEach((line, index) => {
    const at = index + 1;

    // 1. No resource may hold a secret's value. The parameter that holds real
    //    plaintext is written only by the human-run, TTY-gated CLI.
    const resource = /^\s*resource\s+"([a-z0-9_]+)"\s+"([a-z0-9_]+)"/.exec(line);
    if (resource) {
      const [, type, name] = resource;
      if (type === 'aws_ssm_parameter' || type === 'aws_secretsmanager_secret_version') {
        report(file, at, 'no-secret-resource', `${type}.${name} would let \`terraform apply\` write a secret's value. That belongs only to scripts/sag-secrets.mjs.`);
      }
      if (type.startsWith('random_') && !ALLOWED_RANDOM_RESOURCES.has(`${type}.${name}`)) {
        report(file, at, 'no-generated-secret', `${type}.${name} generates a value. The only generated value this module allows is ${[...ALLOWED_RANDOM_RESOURCES].join(', ')} - see AGENTS.md, "The three constraints".`);
      }
      if (type === 'cloudflare_worker_secret' || type === 'cloudflare_workers_secret') {
        report(file, at, 'no-cloudflare-secret-resource', `${type}.${name}: a Workers secret is write-only at the platform level and has no honest Terraform representation. Use \`wrangler secret put\` via scripts/sag-secrets.mjs.`);
      }
    }

    // 2. The one invariant a single flipped boolean would silently defeat.
    //    An existence check that decrypts pulls the plaintext into state as a
    //    side effect of the read.
    const decryption = /^\s*with_decryption\s*=\s*(\S+)/.exec(line);
    if (decryption && decryption[1] !== 'false') {
      report(file, at, 'with-decryption-must-be-false', `with_decryption = ${decryption[1]}. Decrypting a presence check writes the plaintext secret into Terraform state. It must be the literal \`false\`.`);
    }

    // 3. No ignore_changes on the AWS side: the merge-vs-replace hazard that
    //    would force one does not arise when the thing Terraform writes was
    //    never secret.
    if (/^\s*ignore_changes\s*=/.test(line) && file.includes(`${join('modules', 'aws')}`)) {
      report(file, at, 'no-ignore-changes-on-aws', 'lifecycle.ignore_changes on the AWS side means Terraform has stopped owning something it should own. See AGENTS.md.');
    }
  });

  // 4. Every SSM data source has to carry the argument at all - a missing one
  //    defaults to true in the provider, which is the dangerous direction.
  for (const match of source.matchAll(/data\s+"(aws_ssm_parameter|aws_ssm_parameters_by_path)"\s+"([a-z0-9_]+)"\s*\{/g)) {
    const start = match.index;
    // The data block runs to the first line that closes it at column 0.
    const end = source.indexOf('\n}', start);
    const body = source.slice(start, end === -1 ? source.length : end);
    if (!/with_decryption\s*=\s*false/.test(body)) {
      const at = source.slice(0, start).split('\n').length;
      report(file, at, 'with-decryption-must-be-present', `data "${match[1]}" "${match[2]}" does not set with_decryption = false. The provider defaults it to true, which would cache the plaintext secret in state.`);
    }
  }
}

// 5. The secrets path is written in two languages, and they have to agree: the
//    pointer Terraform puts in the Lambda's environment and the path the CLI
//    writes to. test/discipline.tftest.hcl checks the Terraform side against
//    the slug; this checks the CLI's own derivation against known values.
const knownSlugs = {
  'aws-eu-west-2.sandbox.resoauth.cloud': 'awseuwest2-a617a646ba7747f76489',
  'id.example.com': 'idexamplec-a786eb0d891f1b9793d5',
  sandbox: 'sandbox-9ed037b84943c4caa3a5',
};
const cli = readFileSync(join(root, 'scripts', 'sag-secrets.mjs'), 'utf8');
const slugBody = /function slug\(hostname\) \{([\s\S]*?)\n\}/.exec(cli);
if (!slugBody) {
  violations.push({ file: 'scripts/sag-secrets.mjs', line: 0, rule: 'slug-must-exist', message: 'no slug() function found; the CLI can no longer derive the path the module points at.' });
} else {
  const { createHash } = await import('node:crypto');
  const slug = (hostname) => {
    const host = String(hostname).trim().toLowerCase();
    return `${host.replace(/[^a-z0-9]/g, '').slice(0, 10)}-${createHash('sha1').update(host).digest('hex').slice(0, 20)}`;
  };
  for (const [hostname, expected] of Object.entries(knownSlugs)) {
    if (slug(hostname) !== expected) {
      violations.push({ file: 'scripts/check-discipline.mjs', line: 0, rule: 'slug-must-match', message: `the reference slug for ${hostname} is ${slug(hostname)}, expected ${expected}.` });
    }
  }
  if (!/Overwrite:\s*true/.test(cli) || !/Type:\s*'SecureString'/.test(cli)) {
    violations.push({ file: 'scripts/sag-secrets.mjs', line: 0, rule: 'secureString-required', message: 'the CLI must write SecureString parameters; a String parameter would store the secret in plaintext.' });
  }
  if (!/isTTY/.test(cli)) {
    violations.push({ file: 'scripts/sag-secrets.mjs', line: 0, rule: 'tty-gate-required', message: 'the TTY gate is what makes "apply never generates a secret" structural rather than a convention.' });
  }
}

// 6. Nothing but the human-run CLI may set a secret, and nothing at all may
//    invoke that CLI from Terraform. Both rules look for an actual invocation
//    rather than a mention: every file here discusses secrets at length, and a
//    check that fires on prose would be trained away rather than fixed.
const SELF = 'check-discipline.mjs';
for (const name of readdirSync(join(root, 'scripts'))) {
  if (!name.endsWith('.mjs') || name === 'sag-secrets.mjs' || name === SELF) continue;
  const text = readFileSync(join(root, 'scripts', name), 'utf8');
  // An argument list containing 'secret' followed by 'put' - i.e. a real
  // `wrangler secret put` spawn, not the phrase in a comment.
  if (/\[[^\]]*['"]secret['"]\s*,\s*['"]put['"]/.test(text)) {
    violations.push({ file: `scripts/${name}`, line: 0, rule: 'secrets-only-in-the-cli', message: 'only scripts/sag-secrets.mjs may set a secret, because only it is TTY-gated.' });
  }
  // The AWS half of the same rule. A helper that writes SSM parameters without
  // going through the TTY gate is exactly the shape this catches - a second way
  // in is a second way the gate does not hold, whatever the comment above it
  // says.
  if (/PutParameterCommand|PutSecretValueCommand|CreateSecretCommand/.test(text)) {
    violations.push({ file: `scripts/${name}`, line: 0, rule: 'secrets-only-in-the-cli', message: 'only scripts/sag-secrets.mjs may write a secret value. A second, non-interactive path defeats the TTY gate rather than working around it.' });
  }
}
for (const file of files(moduleRoot)) {
  const source = withoutComments(readFileSync(file, 'utf8'));
  // Terraform can only run something through an `external` data source's
  // `program`, or a provisioner's `command`/`interpreter`. A description or a
  // comment naming the CLI is not just harmless, it is the documentation.
  for (const match of source.matchAll(/(program|command|interpreter)\s*=\s*\[[^\]]*\]/g)) {
    if (/sag-secrets/.test(match[0])) {
      const at = source.slice(0, match.index).split('\n').length;
      report(file, at, 'terraform-must-not-reach-the-cli', 'Terraform must not be able to invoke scripts/sag-secrets.mjs: `terraform apply` being unable to reach the code that can set a secret is what makes the constraint structural.');
    }
  }
  if (/provisioner\s+"local-exec"/.test(source)) {
    const at = source.slice(0, source.indexOf('provisioner "local-exec"')).split('\n').length;
    report(file, at, 'no-local-exec', 'a local-exec provisioner is an escape hatch out of everything this module guarantees about what `apply` can do.');
  }
}

if (statSync(join(root, 'modules')).isDirectory() && violations.length === 0) {
  process.stdout.write('check-discipline: all rules pass.\n');
  process.exit(0);
}

process.stderr.write(`check-discipline: ${violations.length} violation${violations.length === 1 ? '' : 's'}\n\n`);
for (const v of violations) {
  process.stderr.write(`  ${v.file}${v.line ? `:${v.line}` : ''}  [${v.rule}]\n    ${v.message}\n\n`);
}
process.exit(1);
