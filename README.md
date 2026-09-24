# sag-terraform-module

Terraform module for deploying an instance of
[SAG](https://github.com/RESOAuth/smart-access-gateway) (Smart Access
Gateway), by RESOAuth Ltd.

It is a module, not a repository you edit per deployment. Each instance is one
small root configuration - a `.tfvars.json` file of facts about one domain, its
own backend, and its own provider credentials - that calls this module for all
of the logic.

```hcl
module "sag" {
  source = "git::https://github.com/RESOAuth/sag-terraform-module.git//modules/sag-instance?ref=v1"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
    cloudflare    = cloudflare
  }

  domain = "id.example.com"
  aws    = { region = "eu-west-2", state_store = "dynamo-db", clients_store = "s3" }
}
```

## What it does, and what it deliberately does not

- **Idempotent, keyed off the domain.** Every resource name derives
  deterministically from one hostname - the first 10 alphanumeric
  characters, a hyphen, and 20 hex characters of its SHA-1 - so the same
  hostname always produces the same names. Fixed length regardless of how
  long the domain is, because AWS caps S3 bucket and IAM role names.
- **There is a state file, and it holds nothing that could open a session.**
  The constraint that survives is the narrow and useful one - *no state that
  would let whoever can read it open a session or forge a token*. A Lambda ARN
  or a KMS key ARN in state is as harmless there as it is in the console, and
  without state there is no drift detection and no reviewable plan.
- **`terraform apply` never generates a session- or encryption-relevant
  secret.** Not `SAG_SECRET`, not `SUBJECT_SALT`, not a signing key, not an
  upstream client secret. There is no `random_password` for one, no variable
  that accepts one, and no data source that reads one back. On AWS the
  Lambda's environment holds `aws:ssm:/sag/<slug>/secrets/<NAME>` - a path,
  not a value - and SAG fetches the real thing at start-up. On Cloudflare,
  Workers secrets are write-only at the platform level, so there is nothing
  for Terraform to hold either way.
- **A plan is a review.** Every name, every environment variable and every
  missing secret is known before anything happens, so a plan posted to a
  pull request is the whole report.

## Getting an instance running

```sh
# 1. First apply of a brand-new instance, with the secrets gate off: the KMS
#    key that secrets are written under does not exist until this has run.
terraform apply -var 'aws={region="eu-west-2",require_secrets=false,...}'

# 2. At a terminal, never in CI. Generates a value, writes it to SSM as a
#    SecureString under this instance's own key, and prints it once.
scripts/sag-secrets.mjs set --instance id.example.com --region eu-west-2 \
  --name SAG_SECRET --generate

# 3. Turn require_secrets back on and apply again. The infrastructure is
#    already there; this time the function starts.
terraform apply
```

A Cloudflare block that keeps state has a second, similar two-phase step, for
a reason worth knowing before it bites: `state_class_created` is false for the
first apply, which creates the Durable Object namespace, and true for every
apply after it. Leave it false and Cloudflare rejects the next upload of the
Worker - the migration carries no `old_tag` to verify against the one already
deployed - and because that field is on the script resource, the rejection
takes the whole upload with it whatever the real change was. The block stays
healthy and serving and stops being modifiable.

Cloudflare invocation logs include complete request URLs and headers, so they
default off to avoid persisting OAuth parameters and session cookies. Set
`cloudflare.invocation_logs` to `true` only when that automatic request capture
is explicitly required; application logs remain enabled either way.

With the gate on, a plan that is missing a secret fails and names it:

```
This instance is blocked on secrets that do not exist yet.
...
Missing: SAG_SECRET, SUBJECT_SALT, UPSTREAM_GOOGLE_COMMON_CLIENT_SECRET
Path:    /sag/awseuwest2-a617a646ba7747f76489/secrets/
Key:     alias/sag-awseuwest2-a617a646ba7747f76489-secrets
```

That is deliberate. SAG treats a secret reference it cannot resolve as a
hard start-up error rather than falling back to an empty value, so applying
with one missing would deploy a function that cannot start.

## An instance config

One `.tfvars.json` per domain. `domain` is the issuer every deployment
shares; each platform block is an independent deployment behind it.

```json
{
  "domain": "id.example.com",
  "sag_version": "bleeding-edge",
  "branding": { "org_name": "Example Ltd" },
  "upstreams": [
    { "provider": "microsoft", "domain": "example.com", "client_id": "..." }
  ],
  "aws": {
    "region": "eu-west-2",
    "state_store": "dynamo-db",
    "clients_store": "s3",
    "cdn": "cloudfront",
    "hosted_zone_id": "Z0123456789ABCDEFGHIJ",
    "email": { "provider": "ses", "from": "Sign in <no-reply@example.com>" }
  }
}
```

Note `sag_version` rather than `version`: Terraform reserves `version` as a
module meta-argument and refuses an input variable by that name. There is no
field for an upstream's `client_secret` either - it is set out-of-band, so
keeping a field for it would only invite a real secret into a git-tracked
file.

[`modules/sag-instance/variables.tf`](modules/sag-instance/variables.tf) is
the contract in full, with the validation rules and every default.

`sag_version` takes `latest`, `bleeding-edge`, a pinned release tag, or
`file:<absolute path>` for a local checkout. **An AWS block currently wants
`bleeding-edge`**: it needs a SAG carrying the `aws:ssm:` mechanism, which
is on `main` but not yet in a release, and `latest` cannot resolve at all
while every published release is a pre-release. The resolved tag and commit
are reported in the `release` output.

## One instance, several deployments

An instance may declare both `cloudflare` and `aws`. Both then need a
`platform_domain` of their own - a hostname for machines, so a health checker
or an operator can reach one specific deployment - while `domain` stays the
single issuer both advertise.

In one root configuration, peers are derived rather than hand-maintained:
every sibling block is automatically a peer of every other, as a complete
mesh, so a half-configured mesh is not something an instance file can
express. `peer_jwks_urls` adds peers from outside that configuration.

Routing `domain` itself to whichever deployment is healthy is out of scope:
that is a traffic-management decision (a Route 53 failover record, a
Cloudflare Load Balancer) and not one to automate generically. Point its
health check at `/healthz`, never `/alive`.

AWS includes the central issuer in its CloudFront aliases and ACM certificate
by default. A CloudFront alias can belong to only one distribution, including
across AWS accounts. Set `aws.serve_issuer_domain = false` on blocks reached
through a separate central ingress: their certificate and distribution then
serve only `aws.platform_domain`, while `SAG_ISSUER` stays the central domain.
The ingress must use the selected platform hostname for the origin's Host
header and TLS name. DNS failover alone does not perform that rewrite.

## Delegating a new AWS platform zone

An AWS block normally uses `hosted_zone_id`, or looks up an existing public
zone by `hosted_zone_name` (defaulting to its platform hostname). Set
`create_hosted_zone = true` to create the platform zone instead:

```hcl
aws = {
  region              = "eu-west-2"
  platform_domain     = "aws-eu-west-2.id.example.com"
  create_hosted_zone  = true
  serve_issuer_domain = false
  require_secrets     = false
}
```

Creation requires an explicit `platform_domain` and `cdn = "cloudfront"`
(the default), and cannot be combined with `hosted_zone_id` or
`hosted_zone_name`. The module puts ACM validation and the platform's A/AAAA
aliases in the new zone. It leaves the parent DNS provider unchanged.

A new zone must be delegated before ACM can validate its certificate. First
review and apply a plan targeting only the zone, using the same remote backend
and deployment pipeline as the eventual full apply:

```sh
terraform plan -target='module.sag.module.aws[0].aws_route53_zone.platform[0]' \
  -out=zone.tfplan
terraform apply zone.tfplan
```

This address assumes the root calls the composed module `sag`. The targeted
apply is for this initial delegation step only; return to an ordinary full
plan after delegation.

The composed output `aws_hosted_zone_delegation` reports the new zone ID and
the NS record to create in its parent, including all four assigned
nameservers. Expose it directly from the root configuration:

```hcl
output "hosted_zone_delegation" {
  value = module.sag.aws_hosted_zone_delegation
}
```

Create that NS record in Cloudflare or whichever provider hosts the parent,
wait for public DNS to resolve through the delegation, then run the full
plan/apply. A full apply before delegation waits for ACM and eventually times
out. Use the dedicated output during bootstrap: the aggregate `module.sag.aws`
output depends on application resources outside the zone-only target and is
not available yet.

After a full apply, the AWS outputs `hosted_zone_id`,
`hosted_zone_name_servers`, and `hosted_zone_delegation` are also available
through `module.sag.aws`. For an existing zone, `hosted_zone_id` reports the
selected zone and the two delegation outputs are null.
`resources.hosted_zone` names only a zone this module creates, so plans
distinguish zone creation from existing-zone use.

## One pipeline per platform

Each block is a separate deployment, and in Terraform that means **one root
configuration per platform block**, each with its own backend and its own
provider credentials - not one configuration with a flag, because provider
credentials are wired in at parse time rather than chosen per invocation.

A Cloudflare-only pipeline sets `cloudflare = {...}` and leaves `aws` null;
the AWS submodule is then never instantiated, so no AWS resource is created.
Terraform still requires the root configuration to supply a configuration for
every provider a child module declares, and the AWS provider - unlike the
Cloudflare one - validates its credentials with an `sts:GetCallerIdentity`
call the moment it is configured, whether or not anything in the graph needs
it. So a Cloudflare-only root configuration gives its unused `aws` and
`aws.us_east_1` providers static placeholder credentials and
`skip_credentials_validation`, rather than a real AWS credential it has no
business holding:

```hcl
provider "aws" {
  region                      = "eu-west-2"
  access_key                  = "unused-by-this-root-configuration"
  secret_key                  = "unused-by-this-root-configuration"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}
```

Adding a platform later needs no coordination beyond that: a second pipeline,
in its own credential scope, starts applying its own root configuration
against the same instance data, with each block's `peer_jwks_urls` naming the
other.

Email is worth deciding per block rather than per instance, because a sender
that works on one platform may drag the other platform's credentials into the
block. `ses` on Lambda needs nothing but a region, since the execution role
supplies the credentials through the environment; `ses` on Workers has no role
to supply anything and needs `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
as Workers secrets, which this module does not model and therefore does not
report. The platform-native pairing is `ses` on AWS and `cloudflare` - Email
Sending, the outbound half of Cloudflare Email Service, bound as `SEND_EMAIL`
- on Cloudflare.

Email Sending needs two things this module cannot provision. The sender's
domain must be onboarded to it, which is per domain and counts a subdomain as
its own, and `cloudflare/cloudflare` 5.x has no resource for that - so it is a
dashboard step, or a REST call with an `Email Sending: Edit` token. And
reaching a recipient who is not a verified destination in the account needs
the Workers Paid plan. Until the domain is onboarded the binding exists, the
block is healthy, and the first OTP fails.

## Adopting an instance that already exists

Terraform's plan/apply cycle *is* the get-or-create reconciliation, with one
caveat worth stating plainly: it reconciles against **state**, not against
the live account. A resource created by hand, or by some earlier tool, needs
an `import` block before Terraform will manage it - it will not discover and
adopt it silently. That is a one-time cost per pre-existing resource, not a
standing limitation.

## Save the plaintext when it is first generated

`npm run secrets` (`sag-secrets.mjs`) prints each generated value once and
cannot store it for you. Put it in whatever vault you already trust, and
treat that as the one deliberate exception to "no keys stored unnecessarily".

`SAG_SECRET` and `SUBJECT_SALT` must be **identical** across every block of
an instance, and neither can be read back off a platform. Adding a second
platform later means setting the *same* plaintext, which is only possible if
it was saved. If it was not: `SAG_SECRET` has a rotation runbook in SAG's own
`docs/operations.md`; `SUBJECT_SALT` has none, because changing it orphans
every account at every relying party.

## Scope

Cloudflare Workers and AWS Lambda. SAG's container adapter is out of scope:
"does this container already exist and is it the right one" depends on
whichever orchestrator is in play, with no single API to reconcile against.

The AWS path has a real worked deployment. The Cloudflare submodule is
written, validates against the provider schema, and passes the test suite,
but has never been applied against a real Cloudflare account - treat it as
unproven.

[docs/aws-secret-references.md](docs/aws-secret-references.md) covers how a
secret gets from a person into the running function, and what does and does
not end up in Terraform state.

## Testing

```sh
cd test && terraform init && terraform test   # no network, no credentials
node scripts/check-discipline.mjs             # the source-level policy check
```

`terraform test` covers the slug derivation, the rendered environment for
each fixture, and the rule that no session- or encryption-relevant secret is
ever a literal value. `check-discipline.mjs` covers what a test asserting on
values structurally cannot: the *absence* of an `aws_ssm_parameter`
resource, of a stray `random_*`, of a `with_decryption` that is not `false`.

[AGENTS.md](AGENTS.md) is the working guide for changing any of this, and the
authority on why it is shaped the way it is.

## Licence

[AGPL-3.0](LICENSE), the same licence as SAG itself.
