# The Cloudflare Workers block: the main Worker, the private HSM Worker it
# reaches over a service binding, and the custom domain that publishes it.
#
# Secrets stay entirely outside Terraform here, and that is a platform property
# rather than a choice this module makes: a Workers secret is write-only, and
# `cloudflare_worker_secret` was removed from the provider at v5.5 precisely
# because there is no honest way to represent a write-only value as a managed
# resource attribute. What makes that safe alongside Terraform owning the rest
# of the bindings list is `keep_bindings`: without it, an apply that rewrote
# `bindings` would delete every secret a person had set, on the ordinary happy
# path, on a run that then reported success.

locals {
  names = {
    worker            = "sag-${var.slug}"
    hsm_worker        = "sag-hsm-${var.slug}"
    clients_namespace = "sag-clients-${var.slug}"
    # The Durable Object class name is SAG's own export, not ours to choose;
    # only the namespace the binding points at is per-instance.
    state_class     = "StateGuard"
    state_binding   = "SAG_STATE"
    clients_binding = "SAG_CLIENTS"
    hsm_binding     = "HSM"
    # SAG reads its send_email binding under whatever CLOUDFLARE_EMAIL_BINDING
    # names, defaulting to SEND_EMAIL. Matching the default means the variable
    # never has to be rendered.
    email_binding = "SEND_EMAIL"
  }

  use_state   = var.block.state_store == "durable-object"
  use_clients = var.block.clients_store == "kv"

  email = var.block.email

  # Cloudflare Email Sending - the outbound half of Email Service, not the
  # inbound Email Routing the two are easily confused for - is the one provider
  # that needs a binding rather than an API key: there is no secret to set, and
  # without the binding SAG throws at the first OTP rather than at start-up, so
  # a block configured for it and missing it looks healthy until somebody tries
  # to sign in.
  #
  # Two things this module cannot do anything about. The sender address must
  # belong to a domain onboarded to Email Sending, which is per domain - a
  # subdomain is its own sending domain - and has no resource in
  # cloudflare/cloudflare 5.x, so it stays a dashboard or REST step needing an
  # `Email Sending: Edit` token. And sending to an address that is not a
  # verified destination in the account needs the Workers Paid plan; verified
  # destinations are free on every plan.
  use_email_binding = local.email != null && local.email.provider == "cloudflare"

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
    local.email.provider != "ses" || local.email.region == null ? {} : { SES_REGION = local.email.region },
    local.email.provider != "ses" || local.email.configuration_set == null ? {} : { SES_CONFIGURATION_SET = local.email.configuration_set },
    local.email.provider != "notify" || local.email.notify_template_id == null ? {} : { NOTIFY_TEMPLATE_ID = local.email.notify_template_id },
    local.email.provider != "cloudflare" || local.email.destination == null ? {} : { CLOUDFLARE_EMAIL_DESTINATION = local.email.destination },
  )

  platform_vars = merge(
    {
      # Workers have no asymmetric key service, so the private key lives in a
      # second Worker reached only over a service binding.
      SIGNING_BACKEND = "cloudflare-hsm"
      SIGNING_ALG     = "ES256"
    },
    local.use_state ? { STATE_STORE_BACKEND = "cf-durable-object" } : {},
    local.use_clients ? { CLIENTS_STORE_BACKEND = "cf-kv" } : {},
    length(var.peer_jwks_urls) == 0 ? {} : { PEER_JWKS_URLS = join(",", var.peer_jwks_urls) },
  )

  environment = merge(
    var.common.vars,
    local.email_vars,
    local.platform_vars,
    var.common.extra_vars,
    var.block.extra_vars,
  )

  # HSM_SHARED_SECRET authenticates the main Worker to the HSM Worker and must
  # be byte-identical on both, which is exactly why nothing here generates it:
  # scripts/sag-secrets.mjs sets both from one value.
  worker_secret_names = sort(distinct(concat(
    var.common.secret_names,
    local.email_secret_names,
    ["HSM_SHARED_SECRET"],
  )))

  hsm_secret_names = ["HSM_SHARED_SECRET", "SIGNING_PRIVATE_JWK"]

  # Sorted, because `bindings` is a list: an unstable order would show up as a
  # diff on every plan with nothing actually changed.
  worker_bindings = concat(
    [for key in sort(keys(local.environment)) : {
      type = "plain_text"
      name = key
      text = local.environment[key]
    }],
    [{
      type    = "service"
      name    = local.names.hsm_binding
      service = local.names.hsm_worker
    }],
    local.use_state ? [{
      type       = "durable_object_namespace"
      name       = local.names.state_binding
      class_name = local.names.state_class
    }] : [],
    local.use_clients ? [{
      type         = "kv_namespace"
      name         = local.names.clients_binding
      namespace_id = cloudflare_workers_kv_namespace.clients[0].id
    }] : [],
    # What the binding chooses is which addresses this Worker may reach:
    # `destination_address` pins it to exactly one, and SAG's sender sends
    # every code to that same address when CLOUDFLARE_EMAIL_DESTINATION is
    # set, so the two have to agree or the send is rejected. With no
    # destination configured SAG sends to the real recipient and the binding is
    # left unrestricted, which reaches any verified destination on any plan and
    # any address at all only on Workers Paid.
    local.use_email_binding ? [merge({
      type = "send_email"
      name = local.names.email_binding
      },
      local.email.destination == null ? {} : { destination_address = local.email.destination },
    )] : [],
  )
}

data "external" "release" {
  program = ["node", "${path.module}/../../scripts/fetch-release.mjs"]

  query = {
    version  = var.common.sag_version
    include  = "package.json,src,adapters"
    platform = "cloudflare"
  }
}

data "external" "worker_bundle" {
  program = ["node", "${path.module}/../../scripts/bundle-worker.mjs"]

  query = {
    source_dir = data.external.release.result.package_dir
    entry      = "adapters/cloudflare/worker.js"
    name       = local.names.worker
    # nodejs_compat is needed by the AWS signing path and the email senders;
    # harmless when unused, because the bundle is tree-shaken.
    compatibility_date  = var.compatibility_date
    compatibility_flags = "nodejs_compat"
  }
}

data "external" "hsm_bundle" {
  program = ["node", "${path.module}/../../scripts/bundle-worker.mjs"]

  query = {
    source_dir          = data.external.release.result.package_dir
    entry               = "adapters/cloudflare/hsm.js"
    name                = local.names.hsm_worker
    compatibility_date  = var.compatibility_date
    compatibility_flags = "nodejs_compat"
  }
}

# --- the private HSM Worker -------------------------------------------------
#
# It holds the signing key and must stay unreachable from the internet: no
# routes, no custom domain, workers.dev off, so the main Worker's service
# binding is the only way in.

resource "cloudflare_workers_script" "hsm" {
  account_id  = var.block.account_id
  script_name = local.names.hsm_worker

  content_file        = data.external.hsm_bundle.result.path
  content_sha256      = data.external.hsm_bundle.result.sha256
  main_module         = "hsm.js"
  compatibility_date  = var.compatibility_date
  compatibility_flags = ["nodejs_compat"]

  bindings = [{
    type = "plain_text"
    name = "SIGNING_ALG"
    text = "ES256"
  }]

  # SIGNING_PRIVATE_JWK and HSM_SHARED_SECRET are set out-of-band and are not
  # representable here. Without this they would be deleted by the next apply.
  keep_bindings = ["secret_text"]

  observability = {
    enabled = true
  }
}

resource "cloudflare_workers_script_subdomain" "hsm" {
  account_id  = var.block.account_id
  script_name = cloudflare_workers_script.hsm.script_name
  enabled     = false
}

# --- the main Worker --------------------------------------------------------

resource "cloudflare_workers_script" "main" {
  account_id  = var.block.account_id
  script_name = local.names.worker

  content_file        = data.external.worker_bundle.result.path
  content_sha256      = data.external.worker_bundle.result.sha256
  main_module         = "worker.js"
  compatibility_date  = var.compatibility_date
  compatibility_flags = ["nodejs_compat"]

  bindings      = local.worker_bindings
  keep_bindings = ["secret_text"]

  migrations = local.use_state ? {
    new_tag            = "v1"
    new_sqlite_classes = [local.names.state_class]
  } : null

  observability = {
    enabled = true
  }

  depends_on = [cloudflare_workers_script.hsm]
}

resource "cloudflare_workers_script_subdomain" "main" {
  account_id  = var.block.account_id
  script_name = cloudflare_workers_script.main.script_name

  # The custom domain below is the only published entry point.
  enabled = false
}

resource "cloudflare_workers_custom_domain" "main" {
  account_id = var.block.account_id
  zone_id    = var.block.zone_id
  hostname   = var.platform_domain
  # Attaching a custom domain creates or replaces the zone's own record for
  # that hostname, which is why the zone is named explicitly rather than
  # discovered.
  service = cloudflare_workers_script.main.script_name
}
