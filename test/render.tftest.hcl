# `terraform plan` against the fixtures produces the expected resource set and
# environment variables, with every provider mocked - no network, no
# credentials.
#
# The fixtures in ./fixtures are three whole instance files, in the same
# `.tfvars.json` shape a root configuration uses.

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

# --- a single AWS block, with CDN and WAF ------------------------------------

run "single_aws" {
  command = plan

  variables {
    instance = jsondecode(file("fixtures/single-aws.json"))
  }

  assert {
    condition     = output.issuer == "https://id.example.com"
    error_message = "SAG_ISSUER must be the central domain, never a platform_domain: got ${output.issuer}"
  }

  # A sole block collapses the central/regional distinction: there is no second
  # deployment for `domain` to have to choose between.
  assert {
    condition     = output.platform_domains["aws"] == "id.example.com"
    error_message = "a sole block should default its platform_domain to the instance domain: got ${output.platform_domains["aws"]}"
  }

  assert {
    condition     = output.aws_block.environment["SIGNING_BACKEND"] == "aws-kms"
    error_message = "the AWS block signs with KMS; the private key never leaves it."
  }

  assert {
    condition     = output.aws_block.environment["SIGNING_KMS_KEY_ID"] == "alias/sag-${output.slugs["aws"]}-signing"
    error_message = "SIGNING_KMS_KEY_ID must name the per-instance alias, not a key id."
  }

  assert {
    condition = alltrue([
      output.aws_block.environment["STATE_STORE_BACKEND"] == "dynamodb",
      output.aws_block.environment["STATE_STORE_TABLE"] == "sag-${output.slugs["aws"]}-state",
      output.aws_block.environment["STATE_STORE_REGION"] == "eu-west-2",
    ])
    error_message = "state_store = dynamo-db must render all three STATE_STORE_* variables."
  }

  assert {
    condition = alltrue([
      output.aws_block.environment["CLIENTS_STORE_BACKEND"] == "s3",
      output.aws_block.environment["CLIENTS_STORE_S3_BUCKET"] == "sag-${output.slugs["aws"]}-clients",
      output.aws_block.environment["CLIENTS_STORE_S3_REGION"] == "eu-west-2",
    ])
    error_message = "clients_store = s3 must render all three CLIENTS_STORE_* variables."
  }

  # SES needs no secret: it authenticates as the function's own execution role.
  assert {
    condition = alltrue([
      output.aws_block.environment["EMAIL_PROVIDER"] == "ses",
      output.aws_block.environment["SES_REGION"] == "eu-west-2",
      !contains(output.aws_block.secret_names, "MAILCHANNELS_API_KEY"),
      !contains(output.aws_block.secret_names, "SMTP_URL"),
    ])
    error_message = "the ses provider should render SES_* variables and require no API key secret."
  }

  # With no upstreams in this fixture, the only secrets are the two every
  # instance needs.
  assert {
    condition     = output.aws_block.secret_names == tolist(["SAG_SECRET", "SUBJECT_SALT"])
    error_message = "unexpected secret set: ${join(", ", output.aws_block.secret_names)}"
  }

  # SAG_SECRET_PREVIOUS is opt-in, because SAG treats a pointer it cannot
  # resolve as a hard start-up error rather than an absent variable.
  assert {
    condition     = !contains(keys(output.aws_block.environment), "SAG_SECRET_PREVIOUS")
    error_message = "SAG_SECRET_PREVIOUS must not appear unless session.rotating is set."
  }

  # cdn = "cloudfront" means the origin header exists. Its value is generated
  # rather than pointed at - the one deliberate exception in the whole module -
  # so it is not known until apply; single_aws_resource_set checks it.
  assert {
    condition     = contains(keys(output.aws_block.environment), "CDN_ORIGIN_SECRET")
    error_message = "CDN_ORIGIN_SECRET should be present when a CDN is in front."
  }

  # The instance's own zone is known, and it is the only subject, so nothing is
  # left for an operator to create by hand.
  assert {
    condition     = length(output.aws_block.unvalidated_domains) == 0
    error_message = "a sole block in a known zone should need no manual validation records: ${join(", ", output.aws_block.unvalidated_domains)}"
  }

  # The resource set, by name. Ids are not knowable before anything exists, but
  # every name is - which is exactly the "same hostname in, same resource names
  # out" property this module is built on.
  assert {
    # Compared as JSON rather than with ==, which warns on two object types
    # that differ only in which attributes are null.
    condition = jsonencode(output.aws_block.resources) == jsonencode({
      cdn                 = true
      certificate_domains = ["id.example.com"]
      clients_bucket      = "sag-${output.slugs["aws"]}-clients"
      dns_records         = ["id.example.com A", "id.example.com AAAA"]
      function            = "sag-${output.slugs["aws"]}"
      log_group           = "/aws/lambda/sag-${output.slugs["aws"]}"
      role                = "sag-${output.slugs["aws"]}-exec"
      secrets_key_alias   = "alias/sag-${output.slugs["aws"]}-secrets"
      signing_key_alias   = "alias/sag-${output.slugs["aws"]}-signing"
      state_table         = "sag-${output.slugs["aws"]}-state"
      waf_acl             = "sag-${output.slugs["aws"]}-waf"
    })
    error_message = "unexpected resource set: ${jsonencode(output.aws_block.resources)}"
  }
}

run "single_aws_rotating" {
  command = plan

  variables {
    instance = merge(
      jsondecode(file("fixtures/single-aws.json")),
      { session = { rotating = true } },
    )
  }

  assert {
    condition     = output.aws_block.environment["SAG_SECRET_PREVIOUS"] == "aws:ssm:/sag/${output.slugs["aws"]}/secrets/SAG_SECRET_PREVIOUS"
    error_message = "session.rotating must add the SAG_SECRET_PREVIOUS pointer."
  }
}

# --- a single Cloudflare block ----------------------------------------------

run "single_cloudflare" {
  command = plan

  variables {
    instance = jsondecode(file("fixtures/single-cloudflare.json"))
  }

  assert {
    condition     = output.cloudflare_block.environment["SIGNING_BACKEND"] == "cloudflare-hsm"
    error_message = "Workers have no asymmetric key service, so the signing key lives in the HSM Worker."
  }

  assert {
    condition = alltrue([
      output.cloudflare_block.environment["STATE_STORE_BACKEND"] == "cf-durable-object",
      output.cloudflare_block.environment["CLIENTS_STORE_BACKEND"] == "cf-kv",
    ])
    error_message = "the Cloudflare backends should be selected by the block's own store settings."
  }

  # SAG carries the email domain as a prefix on the client id value, splitting
  # at the first colon; the catch-all uses the literal `common`.
  assert {
    condition     = output.cloudflare_block.environment["UPSTREAM_MICROSOFT_EXAMPLECOM_CLIENT_ID"] == "example.com:00000000-1111-2222-3333-444444444444"
    error_message = "a domain-scoped upstream must carry its domain as a client id prefix: got ${output.cloudflare_block.environment["UPSTREAM_MICROSOFT_EXAMPLECOM_CLIENT_ID"]}"
  }

  assert {
    condition     = output.cloudflare_block.environment["UPSTREAM_GOOGLE_COMMON_CLIENT_ID"] == "common:555555555555.apps.googleusercontent.com"
    error_message = "the catch-all upstream must render as COMMON with a `common:` prefix."
  }

  assert {
    condition     = output.cloudflare_block.environment["UPSTREAM_MICROSOFT_EXAMPLECOM_TENANT"] == "example.com"
    error_message = "an upstream's tenant must render as UPSTREAM_<P>_<SLUG>_TENANT."
  }

  assert {
    condition     = output.cloudflare_block.environment["UI_ORG_NAME"] == "Example Ltd"
    error_message = "branding should render UI_* variables."
  }

  # HSM_SHARED_SECRET authenticates the main Worker to the HSM Worker, so both
  # need it, and mailchannels needs its API key.
  assert {
    condition = alltrue([
      contains(output.cloudflare_block.secret_names["sag-${output.slugs["cloudflare"]}"], "HSM_SHARED_SECRET"),
      contains(output.cloudflare_block.secret_names["sag-${output.slugs["cloudflare"]}"], "MAILCHANNELS_API_KEY"),
      contains(output.cloudflare_block.secret_names["sag-${output.slugs["cloudflare"]}"], "UPSTREAM_MICROSOFT_EXAMPLECOM_CLIENT_SECRET"),
      contains(output.cloudflare_block.secret_names["sag-hsm-${output.slugs["cloudflare"]}"], "SIGNING_PRIVATE_JWK"),
    ])
    error_message = "unexpected Cloudflare secret set."
  }

  # mailchannels sends over its own HTTP API with an API key, so this block
  # gets no send_email binding - only the provider that needs one gets one.
  assert {
    condition = alltrue([
      output.cloudflare_block.resources.bindings["HSM"] == "service",
      output.cloudflare_block.resources.bindings["SAG_STATE"] == "durable_object_namespace",
      output.cloudflare_block.resources.bindings["SAG_CLIENTS"] == "kv_namespace",
      !contains(keys(output.cloudflare_block.resources.bindings), "SEND_EMAIL"),
    ])
    error_message = "unexpected Cloudflare binding set: ${jsonencode(output.cloudflare_block.resources.bindings)}"
  }

  # Not a single `aws:ssm:` pointer on this platform: Workers secrets are
  # write-only at the platform level, so there is nothing to point at.
  assert {
    condition     = length([for value in values(output.cloudflare_block.environment) : value if startswith(value, "aws:ssm:")]) == 0
    error_message = "the Cloudflare block must not render AWS secret pointers."
  }

  assert {
    condition     = output.aws_block == null
    error_message = "a Cloudflare-only instance must not instantiate the AWS submodule at all."
  }
}

# --- both blocks in one root configuration ----------------------------------

run "multi_cloud_mesh" {
  command = plan

  variables {
    instance = jsondecode(file("fixtures/multi-cloud.json"))
  }

  # Sibling blocks in one configuration are peers of each other, always as a
  # complete mesh, so an asymmetric mesh is not something an instance file can
  # express by accident.
  assert {
    condition     = output.peer_jwks_urls["cloudflare"] == tolist(["https://aws-eu-west-2.id.example.com/.well-known/jwks.json"])
    error_message = "the Cloudflare block should peer with its AWS sibling: got ${join(", ", output.peer_jwks_urls["cloudflare"])}"
  }

  # The explicit list is peers outside this configuration entirely, merged on
  # top of the sibling.
  assert {
    condition = output.peer_jwks_urls["aws"] == tolist([
      "https://cf.id.example.com/.well-known/jwks.json",
      "https://elsewhere.example.org/.well-known/jwks.json",
    ])
    error_message = "the AWS block should peer with its sibling and with the explicit external peer: got ${join(", ", output.peer_jwks_urls["aws"])}"
  }

  assert {
    condition     = output.aws_block.environment["PEER_JWKS_URLS"] == "https://cf.id.example.com/.well-known/jwks.json,https://elsewhere.example.org/.well-known/jwks.json"
    error_message = "PEER_JWKS_URLS is comma separated: got ${output.aws_block.environment["PEER_JWKS_URLS"]}"
  }

  # Both blocks answer on their own hostname, but claim the same issuer.
  assert {
    condition = alltrue([
      output.issuer == "https://id.example.com",
      output.aws_block.environment["SAG_ISSUER"] == "https://id.example.com",
      output.cloudflare_block.environment["SAG_ISSUER"] == "https://id.example.com",
    ])
    error_message = "every block of one instance must claim the same issuer."
  }

  assert {
    condition     = output.slugs["aws"] != output.slugs["cloudflare"]
    error_message = "two blocks on different hostnames must get different slugs."
  }

  # Each block sends through its own platform's service: SES on Lambda, where
  # the execution role supplies the credentials, and Email Routing on Workers,
  # where there is no role to supply anything. Email Routing is the one
  # provider that needs a binding rather than an API key, so it must add
  # SEND_EMAIL and must not add a secret name.
  assert {
    condition = alltrue([
      output.cloudflare_block.resources.bindings["SEND_EMAIL"] == "send_email",
      output.cloudflare_block.environment["EMAIL_PROVIDER"] == "cloudflare",
      output.cloudflare_block.environment["CLOUDFLARE_EMAIL_DESTINATION"] == "codes@example.com",
      output.aws_block.environment["EMAIL_PROVIDER"] == "ses",
    ])
    error_message = "the Cloudflare block should send through Email Routing, bound as SEND_EMAIL."
  }

  assert {
    condition = output.cloudflare_block.secret_names["sag-${output.slugs["cloudflare"]}"] == tolist([
      "HSM_SHARED_SECRET",
      "SAG_SECRET",
      "SUBJECT_SALT",
      "UPSTREAM_MICROSOFT_COMMON_CLIENT_SECRET",
    ])
    error_message = "Email Routing needs no API key, so it must add no secret: got ${jsonencode(output.cloudflare_block.secret_names["sag-${output.slugs["cloudflare"]}"])}"
  }

  # cdn = "none" on this block: no distribution, no certificate, no DNS and no
  # origin header, because there is no CDN in front to send one.
  assert {
    condition = alltrue([
      output.aws_block.resources.cdn == false,
      length(output.aws_block.resources.certificate_domains) == 0,
      length(output.aws_block.resources.dns_records) == 0,
      output.aws_block.resources.waf_acl == null,
      !contains(keys(output.aws_block.environment), "CDN_ORIGIN_SECRET"),
    ])
    error_message = "cdn = none must create no CDN resources and render no origin secret."
  }

  # state_store is set but clients_store defaults to "none" on this block.
  assert {
    condition = alltrue([
      output.aws_block.resources.state_table == "sag-${output.slugs["aws"]}-state",
      output.aws_block.resources.clients_bucket == null,
    ])
    error_message = "a store set to none must produce no resource for it."
  }

  # clients_store defaults to "none" on this block, so no bucket variables.
  assert {
    condition     = !contains(keys(output.aws_block.environment), "CLIENTS_STORE_BACKEND")
    error_message = "clients_store = none must render no CLIENTS_STORE_* variables."
  }
}

# --- the escape hatch and the reserved-name filter --------------------------

run "extra_vars_layer_and_reserved_names_are_dropped" {
  command = plan

  variables {
    instance = merge(
      jsondecode(file("fixtures/single-aws.json")),
      {
        extra_vars = { LOG_LEVEL = "debug", CUSTOM_ONE = "instance-wide" }
      },
      {
        aws = merge(
          jsondecode(file("fixtures/single-aws.json")).aws,
          {
            extra_vars = {
              CUSTOM_ONE       = "block-specific"
              AWS_REGION       = "eu-central-1"
              LAMBDA_TASK_ROOT = "/nope"
            }
          },
        )
      },
    )
  }

  assert {
    condition     = output.aws_block.environment["CUSTOM_ONE"] == "block-specific"
    error_message = "a block's extra_vars must override the instance-wide ones."
  }

  assert {
    condition     = output.aws_block.environment["LOG_LEVEL"] == "debug"
    error_message = "extra_vars must be able to override a modelled variable."
  }

  # Lambda refuses to set these, and a rejected UpdateFunctionConfiguration is a
  # confusing way to discover that an escape hatch was used badly.
  assert {
    condition = alltrue([
      !contains(keys(output.aws_block.environment), "AWS_REGION"),
      !contains(keys(output.aws_block.environment), "LAMBDA_TASK_ROOT"),
    ])
    error_message = "runtime-reserved variable names must be filtered out, not passed through."
  }
}
