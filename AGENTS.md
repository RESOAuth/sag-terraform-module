# AGENTS.md

## What this is

`sag-terraform-module`: a Terraform module for deploying instances of SAG
(Smart Access Gateway), by RESOAuth Ltd. This repository holds all of the
logic; the facts about any one deployment - its domain and its per-instance
settings - live in whatever root configuration calls it, not here.

The brief this was built to, unchanged:

> Develop a mechanism for deploying an instance of SAG. The ideal is an
> idempotent process keyed off the domain, there shouldn't be IaC state (I
> don't want keys stored unnecessarily). The ideal is some sort of module
> that can be separately called from an 'instances' repo.

**The module is built and the AWS path has a real worked deployment.** The
Cloudflare submodule is written and covered by `terraform test`, but has never
been applied against a real Cloudflare account. Treat it as unproven, not as
finished.

## The three constraints everything else follows from

1. **Idempotent, keyed off the domain.** A fixed-length, hash-based slug
   (lower-cased hostname, first 10 alphanumeric characters, a hyphen, first
   20 hex characters of its SHA-1), as a Terraform `locals` expression
   shared by both submodules via `modules/sag-instance`. Same hostname in,
   same resource names out. It is written a second time in
   `scripts/sag-secrets.mjs`, because Terraform cannot call into JavaScript
   and that script deliberately cannot call Terraform;
   `scripts/check-discipline.mjs` pins both against known values so they
   cannot drift apart silently.
2. **A real Terraform state exists, and that is a deliberate trade, not a
   compromise.** The constraint that survives is narrower than "no state":
   *no state that would let whoever can read it open a session or forge a
   token*. Ordinary infrastructure metadata (a Lambda ARN, a KV namespace
   ID, a KMS key ARN, an S3 bucket name) in state is fine.
   `docs/aws-secret-references.md`, "What ends up where", is the table that
   settles any particular case.
3. **`terraform apply` never generates a session- or encryption-relevant
   secret value.** Not `SAG_SECRET`, not `SUBJECT_SALT`, not a signing key,
   not `HSM_SHARED_SECRET`, not an upstream client secret. No
   `random_password` resource, no variable default, no data source that
   reads one back, and no field in the instance contract that accepts one.
   Every one of those is set by a person, out-of-band, via
   `scripts/sag-secrets.mjs`, which is human-run, refuses to run without a
   TTY, and is never invoked by `terraform apply`. `CDN_ORIGIN_SECRET`
   remains the one deliberately-generated exception, because it protects
   nothing SAG's own request handling checks - grep `smart-access-gateway`
   for the name and there is nothing to find. It is
   `random_id.cdn_origin_secret`, allow-listed by that exact address in
   `scripts/check-discipline.mjs`; a second exception has to be argued for
   here and then added there deliberately.

## Where things are

- `modules/sag-instance/` - the composed module a root configuration calls:
  `variables.tf` is the contract, `main.tf` computes the slug, the issuer,
  the peer mesh and every SAG variable that is not platform-specific, and
  wires the two platform submodules together. Rendering the shared
  variables here rather than in each submodule is deliberate: two
  independent copies would eventually disagree about a SAG variable name.
- `modules/cloudflare/` and `modules/aws/` - one directory per platform
  block. Nothing in `sag-instance` knows a Cloudflare-specific or
  AWS-specific resource name; that stays entirely inside its own submodule.
- `scripts/fetch-release.mjs` - resolves `latest`/`bleeding-edge`/a pinned
  tag/`file:<path>` and stages the source, invoked as a `data "external"`
  source from both submodules. Dependency-free on purpose: it runs from
  inside a module `terraform init` may have fetched straight from git,
  where there is no `npm install` step. It normalises every staged file's
  mtime to a fixed epoch so `archive_file` produces a byte-identical zip
  from identical source - without that, every apply reports a code update
  it cannot explain.
- `scripts/bundle-worker.mjs` - `adapters/cloudflare/worker.js` is not a
  bundle; it imports `../../src/index.js`. Terraform cannot bundle and the
  Cloudflare API will not take a hand-assembled multi-file upload, so this
  shells out to `wrangler deploy --dry-run --outdir`, which needs no
  credentials and uploads nothing. The upload itself stays a Terraform
  resource.
- `scripts/sag-secrets.mjs` - the one human-run, TTY-gated CLI that ever
  handles a secret's plaintext. Cloudflare: `wrangler secret put`. AWS:
  `ssm:PutParameter` (`SecureString`) directly. Never runs `terraform`,
  never touches Lambda directly.
- `scripts/check-discipline.mjs` - the source-level half of the policy
  check. See "Testing".
- `test/` - the `terraform test` harness (`main.tf`), shared provider mocks
  (`mocks/`), fixtures (`fixtures/`), and the three `.tftest.hcl` suites.

## Conventions to follow

- **British English, Oxford commas, hyphens instead of em-dashes**, terse
  and direct - matching `smart-access-gateway`'s own docs, since the two
  are read together.
- A block is **ready** (plan/apply succeeds), **blocked** (a plan-time
  error names the missing secret), or the operator simply has not given it
  credentials in this run (a separate root configuration and provider block
  they are not running). Do not blur them. **Blocked** is a `precondition`
  on `aws_lambda_function`, gated by `aws.require_secrets`; turn that off
  for the first apply of a brand-new instance, because the KMS key the CLI
  writes under does not exist until something has been applied.
- Every resource is get-or-create via Terraform's own plan/apply cycle -
  that *is* the reconciliation. One caveat: it reconciles against **state**,
  not the live account, so a resource that already exists outside this
  Terraform needs an `import` block before Terraform will manage it; it
  will not silently adopt it. Terraform 1.16 honours only **one** plain
  `import` block per `for_each` resource and silently plans the other
  instances as creates - use a single `import` block with its own
  `for_each` instead.
- On AWS, a secret is never held by a Terraform-managed resource - only an
  `aws:ssm:/sag/<slug>/secrets/<NAME>` pointer, computed entirely at plan
  time. Any SSM presence check exists purely for the **blocked** signal and
  must set `with_decryption = false`, without exception - decrypting it
  would pull the plaintext secret into state as a side effect of the read.
  Both `test/discipline.tftest.hcl` and `scripts/check-discipline.mjs`
  assert this.
- Cloudflare secrets stay entirely outside Terraform: Workers secrets are
  write-only at the platform level, and `cloudflare_worker_secret` was
  removed from the provider at v5.5 for exactly that reason. Terraform owns
  the rest of the `bindings` list, which is only safe because
  `keep_bindings = ["secret_text"]` stops an apply deleting every secret a
  person set - without it, an ordinary successful run would wipe them.
- An email provider that needs a **binding** rather than a secret needs the
  binding written here, because nothing else will notice it is missing.
  `cloudflare` is the only one: SAG's `src/email/cloudflare.js` reads the
  `send_email` binding named by `CLOUDFLARE_EMAIL_BINDING`, defaulting to
  `SEND_EMAIL`, and throws at the first OTP rather than at start-up, so a
  block configured for it without the binding plans clean, applies clean and
  looks healthy. `local.use_email_binding` in `modules/cloudflare/main.tf`
  adds it, and the `resources.bindings` output exists so
  `test/render.tftest.hcl` can assert on it.
- The provider is **Email Sending**, the outbound half of Cloudflare Email
  Service - not Email Routing, which is inbound and whose verified-destination
  list is not what governs outbound delivery. Do not describe it as Email
  Routing, and do not reach for a routing address when diagnosing a send. Two
  parts of it are outside this module by necessity: the sender's domain has to
  be onboarded to Email Sending, per domain and with a subdomain counting as
  its own, and `cloudflare/cloudflare` 5.x has no resource for that; and
  reaching an address that is not a verified destination needs Workers Paid.
  Both belong in an instance's own notes, not here.
- **No `lifecycle.ignore_changes` anywhere on the AWS side.** The
  merge-vs-replace hazard that would force one does not arise when the
  thing Terraform writes was never secret.
- **Use the established provider or library rather than hand-rolling it.**
  `@aws-sdk/client-ssm` and `wrangler` inside the human-run scripts; the
  official `hashicorp/aws` and `cloudflare/cloudflare` Terraform providers
  for everything else. The AWS provider must be `>= 6.0`:
  `aws_lambda_permission.invoked_via_function_url` does not exist before
  it, and a public Function URL cannot be expressed without it.
- A `checkov:skip` needs a real argument in the comment, not a
  restatement of the rule. The suppression *is* the record of the decision.
- The name in resource descriptions and the `ManagedBy` tag is `sag`, not
  the repository name. Changing it rewrites tags and forces replacement of
  the Lambda permissions on every live instance, so leave it alone.

## Testing

Run all three before calling anything done:

```
cd test && terraform init && terraform test   # 15 cases, no network, no credentials
node scripts/check-discipline.mjs             # the source-level policy check
terraform fmt -recursive -check modules test
```

The suites, and the split between them:

- `test/naming.tftest.hcl` - the slug is deterministic and fixed-length
  across a range of hostname lengths, including one shorter than the
  10-character prefix and two that strip to the same prefix. Two cases pin
  the slugs of live deployments: if either fails, the module has stopped
  being able to find the resources it already manages.
- `test/render.tftest.hcl` - `terraform plan` against the fixtures in
  `test/fixtures/` produces the expected resource set and environment
  variables, every provider mocked.
- `test/discipline.tftest.hcl` - the value-level half of the policy check:
  every session- or encryption-relevant secret is an `aws:ssm:` pointer and
  never a literal, every implied secret has a pointer, the Cloudflare block
  renders no secret at all, and the missing-secret list matches what the
  gate would block on.
- `scripts/check-discipline.mjs` - the source-level half, because
  `terraform test` asserts on values and cannot see the *absence* of a
  resource block that was never written. It rejects an `aws_ssm_parameter`
  resource, any `random_*` outside the allow-list, a `with_decryption` that
  is missing or not `false`, an `ignore_changes` on the AWS side, a
  `local-exec` provisioner, and any Terraform `program`/`command` that
  reaches `sag-secrets.mjs`. Every rule has been checked to fire on a real
  violation, not just to pass.

If one of these gets in your way, the change is probably wrong rather than
the test.

Then run `tflint` (per module directory) and `checkov -d modules`, matching
what CI runs. tflint is clean, and checkov's Terraform checks are 0 failed
with 26 documented skips. Its secrets scanner reports one false positive -
CKV_SECRET_6 on the AWS-managed CloudFront origin request policy UUID in
`modules/aws/cdn.tf`, which is a published constant, not a secret.

## What remains

- One real worked Cloudflare deployment, from its own credential scope.
  Nothing here has ever been applied against a Cloudflare account.
- `sag_version` should be pinned to a real release tag as soon as one
  carries the `aws:ssm:` mechanism. `latest` cannot resolve today - GitHub
  excludes pre-releases from it, and `v0.1.0` is one - so an AWS block
  wants `bleeding-edge` until then.
