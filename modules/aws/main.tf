# Every AWS resource name, and the Lambda's whole environment, computed at plan
# time from the slug and the instance configuration - no lookups, nothing
# remembered.
#
# The block-agnostic half of the environment arrives already rendered in
# `var.common.vars`, from modules/sag-instance. What is added here is this
# platform's own backend selection, its email provider's variables, and the
# secret pointers.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  region     = var.block.region
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  names = {
    function      = "sag-${var.slug}"
    role          = "sag-${var.slug}-exec"
    role_policy   = "sag-${var.slug}-exec-policy"
    signing_alias = "alias/sag-${var.slug}-signing"
    secrets_alias = "alias/sag-${var.slug}-secrets"
    state_table   = "sag-${var.slug}-state"
    # S3 bucket names are globally unique across all of AWS and must be
    # lower-case: the slug already satisfies both, and `sag-` plus 31
    # characters stays well inside the 63-character cap.
    clients_bucket = "sag-${var.slug}-clients"
    log_group      = "/aws/lambda/sag-${var.slug}"
    waf_acl        = "sag-${var.slug}-waf"
  }

  # Where the out-of-band CLI writes plaintext and Terraform never does. See
  # docs/aws-secret-references.md, "The path a secret takes".
  secrets_prefix = "/sag/${var.slug}/secrets"

  tags = merge({ ManagedBy = "sag" }, var.common.tags)

  handler = "adapters/lambda/handler.handler"

  # --- email --------------------------------------------------------------

  email = var.block.email

  # Which secret an email provider needs, if any. SES uses the function's own
  # execution role and so needs none.
  email_secret_names = local.email == null ? [] : lookup({
    mailchannels = ["MAILCHANNELS_API_KEY"]
    notify       = ["NOTIFY_API_KEY"]
    smtp         = ["SMTP_URL"]
  }, local.email.provider, [])

  email_vars = local.email == null ? {} : merge(
    { EMAIL_PROVIDER = local.email.provider },
    local.email.from == null ? {} : { EMAIL_FROM = local.email.from },
    local.email.reply_to == null ? {} : { EMAIL_REPLY_TO = local.email.reply_to },
    local.email.subject == null ? {} : { EMAIL_OTP_SUBJECT = local.email.subject },
    # Falls back to AWS_REGION, which Lambda sets; naming it explicitly is cheap
    # and keeps the value visible in the plan.
    local.email.provider != "ses" ? {} : { SES_REGION = coalesce(local.email.region, local.region) },
    local.email.provider != "ses" || local.email.configuration_set == null ? {} : { SES_CONFIGURATION_SET = local.email.configuration_set },
    local.email.provider != "notify" || local.email.notify_template_id == null ? {} : { NOTIFY_TEMPLATE_ID = local.email.notify_template_id },
    local.email.provider != "cloudflare" || local.email.destination == null ? {} : { CLOUDFLARE_EMAIL_DESTINATION = local.email.destination },
  )

  # `Sign in <no-reply@acme.example.com>` -> `no-reply@acme.example.com`.
  email_from_address = (
    local.email == null || local.email.from == null
    ? null
    : try(regex("<([^>]+)>", local.email.from)[0], trimspace(local.email.from))
  )

  # --- this platform's own backend selection ------------------------------

  platform_vars = merge(
    {
      # The private key is generated inside KMS and never leaves it, so there is
      # no SIGNING_PRIVATE_JWK on this platform at all.
      SIGNING_BACKEND    = "aws-kms"
      SIGNING_ALG        = "ES256"
      SIGNING_KMS_KEY_ID = local.names.signing_alias
      SIGNING_KMS_REGION = local.region
    },
    var.block.state_store != "dynamo-db" ? {} : {
      STATE_STORE_BACKEND = "dynamodb"
      STATE_STORE_TABLE   = local.names.state_table
      STATE_STORE_REGION  = local.region
    },
    var.block.clients_store != "s3" ? {} : {
      CLIENTS_STORE_BACKEND   = "s3"
      CLIENTS_STORE_S3_BUCKET = local.names.clients_bucket
      CLIENTS_STORE_S3_REGION = local.region
    },
    length(var.peer_jwks_urls) == 0 ? {} : { PEER_JWKS_URLS = join(",", var.peer_jwks_urls) },
  )

  # --- secrets ------------------------------------------------------------

  secret_names = sort(distinct(concat(var.common.secret_names, local.email_secret_names)))

  # A plain string, built here, with no data source required to produce it and
  # present whether or not the parameter behind it exists yet. The environment
  # variable is a pointer, never the secret: see
  # docs/aws-secret-references.md.
  secret_pointer_vars = {
    for name in local.secret_names : name => "aws:ssm:${local.secrets_prefix}/${name}"
  }

  # --- the whole environment ----------------------------------------------

  cdn_enabled = var.block.cdn == "cloudfront"

  # Lambda refuses to set any of these: the runtime owns them. Filtered rather
  # than trusted, because extra_vars is an open escape hatch and a rejected
  # UpdateFunctionConfiguration is a confusing way to find that out.
  reserved = [
    "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN", "AWS_LAMBDA_FUNCTION_NAME", "AWS_LAMBDA_FUNCTION_VERSION",
    "AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "AWS_LAMBDA_LOG_GROUP_NAME", "AWS_LAMBDA_LOG_STREAM_NAME",
    "AWS_EXECUTION_ENV", "LAMBDA_TASK_ROOT", "LAMBDA_RUNTIME_DIR", "_HANDLER", "_X_AMZ_TRACE_ID",
  ]

  environment = {
    for key, value in merge(
      var.common.vars,
      local.email_vars,
      local.platform_vars,
      local.secret_pointer_vars,
      # Instance-wide first, then the block's own, so a block can override.
      var.common.extra_vars,
      var.block.extra_vars,
      # Last, so an escape hatch cannot shadow it into or out of existence.
      local.cdn_enabled ? { CDN_ORIGIN_SECRET = random_id.cdn_origin_secret[0].b64_url } : {},
    ) : key => value if !contains(local.reserved, key)
  }
}
