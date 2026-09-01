# The policy check on "The three constraints", asserted against what the module
# actually plans rather than left to prose.
#
# What can be checked from a plan is checked here. What can only be checked by
# reading the module's source - that no `aws_ssm_parameter` *resource* exists
# anywhere, that no `random_*` resource other than the one allowed exception
# exists, that no `lifecycle.ignore_changes` exists on the AWS side - is checked
# by scripts/check-discipline.mjs, because `terraform test` asserts on values
# and cannot see the absence of a resource block that was never written.
#
# If one of these gets in your way, the change is probably wrong rather than the
# test.

mock_provider "aws" {
  source = "./mocks/aws"
}
mock_provider "aws" {
  alias  = "us_east_1"
  source = "./mocks/aws"
}
mock_provider "cloudflare" {}
mock_provider "archive" {
  source = "./mocks/archive"
}
mock_provider "external" {
  source = "./mocks/external"
}
mock_provider "random" {
  source = "./mocks/random"
}

# Every session- or encryption-relevant secret this configuration can
# name at once: two upstream client secrets, an email API key, rotation on, and
# a CDN in front so the one deliberate exception is present too.
variables {
  instance = {
    domain = "id.example.com"
    aws = {
      region          = "eu-west-2"
      state_store     = "dynamo-db"
      clients_store   = "s3"
      cdn             = "cloudfront"
      hosted_zone_id  = "Z0123456789ABCDEFGHIJ"
      require_secrets = false
      email           = { provider = "mailchannels", from = "Sign in <no-reply@example.com>" }
    }
    session = { rotating = true }
    upstreams = [
      { provider = "microsoft", domain = "example.com", client_id = "aaa" },
      { provider = "google", client_id = "bbb" },
    ]
  }
}

run "no_session_or_encryption_secret_is_ever_a_value" {
  command = plan

  # The whole point of the module. Every one of these is set by a person,
  # out-of-band, via scripts/sag-secrets.mjs; what Terraform writes to the
  # Lambda is only ever the pointer that names it.
  assert {
    condition = alltrue([
      for name in [
        "SAG_SECRET",
        "SAG_SECRET_PREVIOUS",
        "SUBJECT_SALT",
        "MAILCHANNELS_API_KEY",
        "UPSTREAM_MICROSOFT_EXAMPLECOM_CLIENT_SECRET",
        "UPSTREAM_GOOGLE_COMMON_CLIENT_SECRET",
      ] :
      output.aws_block.environment[name] == "aws:ssm:/sag/${output.slugs["aws"]}/secrets/${name}"
    ])
    error_message = "a session- or encryption-relevant secret is not an aws:ssm: pointer. See docs/aws-secret-references.md."
  }

  # Stated separately from the assertion above, because the failure mode this
  # catches is different: a new secret added to the table but not to the
  # environment would leave SAG reading an unset variable rather than a wrong
  # one, and the two need telling apart.
  assert {
    condition = alltrue([
      for name in output.aws_block.secret_names :
      contains(keys(output.aws_block.environment), name)
    ])
    error_message = "a secret this instance implies has no pointer in the environment: ${join(", ", output.aws_block.secret_names)}"
  }

  # A pointer names a path, not a value, and that path is derivable from the
  # slug by anyone who already has the config - so the pointer itself reveals
  # nothing. This asserts the shape stays that way: SSM only, never `aws:kms:`
  # (ciphertext in state) and never `aws:secretsmanager:`.
  assert {
    condition = alltrue([
      for name in output.aws_block.secret_names :
      startswith(output.aws_block.environment[name], "aws:ssm:/sag/")
    ])
    error_message = "this module uses the aws:ssm: form only - see docs/aws-secret-references.md for why not aws:kms: or aws:secretsmanager:."
  }

  # The one exception, named explicitly so adding a second one has to come here
  # and argue for itself. CDN_ORIGIN_SECRET is a real generated value because
  # SAG's own request handling never reads it: grep smart-access-gateway for it
  # and there is nothing to find.
  assert {
    condition = length([
      for name, value in output.aws_block.environment :
      name if !startswith(value, "aws:ssm:") && contains([
        "SAG_SECRET", "SAG_SECRET_PREVIOUS", "SUBJECT_SALT", "SIGNING_PRIVATE_JWK",
        "HSM_SHARED_SECRET", "MAILCHANNELS_API_KEY", "NOTIFY_API_KEY", "SMTP_URL",
      ], name) || (endswith(name, "_CLIENT_SECRET") && !startswith(value, "aws:ssm:"))
    ]) == 0
    error_message = "a session- or encryption-relevant secret has a literal value in the Lambda's environment."
  }
}

run "the_blocked_gate_names_what_is_missing" {
  command = plan

  # The mocked SSM listing is empty, which is the true state of a brand-new
  # instance. With the gate off, the module still reports what a person has to
  # set; with it on, this same list is what fails the plan - proven against a
  # real account, because a mocked precondition failure cannot be
  # asserted on from inside a run block.
  assert {
    condition     = output.aws_block.missing_secrets == output.aws_block.secret_names
    error_message = "with nothing set, every secret should be reported missing: ${join(", ", output.aws_block.missing_secrets)}"
  }

  assert {
    condition     = length(output.aws_block.missing_secrets) == 6
    error_message = "expected six secrets for this configuration, got ${length(output.aws_block.missing_secrets)}: ${join(", ", output.aws_block.missing_secrets)}"
  }

  # The path the CLI writes to and the path the pointer names have to be the
  # same string, and they are computed in two different languages - Terraform
  # here, JavaScript in scripts/sag-secrets.mjs. This is the assertion that
  # notices if they ever drift apart.
  assert {
    condition     = output.aws_block.secrets_path == "/sag/${output.slugs["aws"]}/secrets/"
    error_message = "the secrets path must be derived from the slug: got ${output.aws_block.secrets_path}"
  }
}

run "cloudflare_holds_no_secret_at_all" {
  command = plan

  variables {
    instance = {
      domain = "id.example.com"
      cloudflare = {
        account_id    = "0123456789abcdef0123456789abcdef"
        zone_id       = "fedcba9876543210fedcba9876543210"
        state_store   = "durable-object"
        clients_store = "kv"
        email         = { provider = "mailchannels", from = "Sign in <no-reply@example.com>" }
      }
      session   = { rotating = true }
      upstreams = [{ provider = "google", client_id = "bbb" }]
    }
  }

  # A Workers secret is write-only at the platform level, so there is nothing to
  # represent and nothing to point at. Every secret name this block implies must
  # therefore be absent from the rendered variables entirely - not present as a
  # pointer, and certainly not as a value.
  assert {
    condition = length([
      for name in flatten(values(output.cloudflare_block.secret_names)) :
      name if contains(keys(output.cloudflare_block.environment), name)
    ]) == 0
    error_message = "a Cloudflare secret name appears among the plain-text bindings."
  }

  assert {
    condition     = output.aws_block == null
    error_message = "a Cloudflare-only configuration must not instantiate the AWS submodule."
  }
}
