# The composed module a root configuration calls.
#
# Everything platform-specific lives in modules/aws and modules/cloudflare;
# nothing in this file knows an AWS or Cloudflare resource name. What it does
# own is the three things both blocks have to agree on: the identity every
# resource name derives from, the issuer, and the peer JWKS mesh.

locals {
  # What every resource name is keyed off: a domain when there is one, so the
  # "idempotent, keyed off the domain" property is unchanged, and a `name` when
  # there is not, so it is still a stable identifier taken from the
  # configuration rather than anything a run has to remember.
  # Deliberately not coalesce(): coalesce() with every argument null is itself
  # an error, which would replace the precondition's explanation below with an
  # opaque one from a locals expression.
  identity = var.domain != null ? var.domain : var.name

  domainless = var.domain == null

  present = compact([
    var.cloudflare == null ? "" : "cloudflare",
    var.aws == null ? "" : "aws",
  ])
  sole = length(local.present) == 1

  # A sole block collapses the central/regional distinction: there is no second
  # deployment for `domain` to have to choose between.
  cloudflare_platform_domain = (
    var.cloudflare == null ? null :
    var.cloudflare.platform_domain != null ? var.cloudflare.platform_domain :
    local.sole ? var.domain : null
  )
  aws_platform_domain = (
    var.aws == null ? null :
    var.aws.platform_domain != null ? var.aws.platform_domain :
    local.sole ? var.domain : null
  )

  # Never derived from a request: a Host header must not get to decide what SAG
  # claims to be. Always the central domain, never a platform_domain.
  issuer = local.domainless ? null : "https://${var.domain}"

  # The peer mesh, for the combined root-configuration shape. Sibling blocks in
  # one configuration are peers of each other, always as a complete mesh, so an
  # asymmetric mesh is not something an instance file can express by accident;
  # `peer_jwks_urls` on a block is peers outside this configuration entirely,
  # merged on top. The split shape has no siblings here, so it is exactly the
  # explicit list and nothing more.
  cloudflare_peers = var.cloudflare == null ? [] : distinct(concat(
    local.aws_platform_domain == null ? [] : ["https://${local.aws_platform_domain}/.well-known/jwks.json"],
    var.cloudflare.peer_jwks_urls,
  ))
  aws_peers = var.aws == null ? [] : distinct(concat(
    local.cloudflare_platform_domain == null ? [] : ["https://${local.cloudflare_platform_domain}/.well-known/jwks.json"],
    var.aws.peer_jwks_urls,
  ))

  # The shared, fixed-length, hash-based slug, once, here, for both platforms:
  # lower-case the resource key, keep the first 10 alphanumeric characters,
  # append a hyphen and the first 20 hex characters of its SHA-1. Fixed length
  # regardless of hostname length, because AWS caps S3 bucket and IAM role
  # names at 63-64 characters and an unbounded slug would eventually reach
  # that. The tail is hashed rather than truncated so two hostnames sharing a
  # 10-character prefix do not collide, and the hash covers the whole hostname,
  # punctuation included, so `a.bexample.com` and `ab.example.com` stay
  # distinct even though they strip to the same prefix.
  cloudflare_resource_key = local.domainless ? var.name : local.cloudflare_platform_domain
  aws_resource_key        = local.domainless ? var.name : local.aws_platform_domain

  cloudflare_alnum = local.cloudflare_resource_key == null ? "" : replace(lower(local.cloudflare_resource_key), "/[^a-z0-9]/", "")
  aws_alnum        = local.aws_resource_key == null ? "" : replace(lower(local.aws_resource_key), "/[^a-z0-9]/", "")

  cloudflare_slug = local.cloudflare_resource_key == null ? null : format(
    "%s-%s",
    substr(local.cloudflare_alnum, 0, min(10, length(local.cloudflare_alnum))),
    substr(sha1(lower(local.cloudflare_resource_key)), 0, 20),
  )
  aws_slug = local.aws_resource_key == null ? null : format(
    "%s-%s",
    substr(local.aws_alnum, 0, min(10, length(local.aws_alnum))),
    substr(sha1(lower(local.aws_resource_key)), 0, 20),
  )

  # --- the SAG environment every block shares -----------------------------
  #
  # Rendered here, once, rather than in each platform submodule: the variable
  # names and value formats are SAG's, `src/config.js` in smart-access-gateway
  # is the authority, and two independent copies of this would eventually
  # disagree. Each submodule adds its own backend selection, its own email
  # provider variables and its own peer list on top.
  #
  # Keying the upstream map by the rendered prefix is what catches two upstreams
  # that would render as the same UPSTREAM_<PROVIDER>_<SLUG>_*: Terraform
  # rejects a duplicate object key rather than letting one silently overwrite
  # the other.
  upstream_entries = {
    for up in var.upstreams :
    "UPSTREAM_${upper(up.provider)}_${up.domain == null ? "COMMON" : replace(upper(up.domain), "/[^A-Z0-9]/", "")}" => up
  }

  upstream_vars = merge(concat([{}], [
    for prefix, up in local.upstream_entries : merge(
      # SAG carries the email domain as a prefix on the client id value rather
      # than in a field of its own, splitting at the first colon. The catch-all
      # uses the literal `common`.
      { "${prefix}_CLIENT_ID" = "${up.domain == null ? "common" : up.domain}:${up.client_id}" },
      up.tenant == null ? {} : { "${prefix}_TENANT" = up.tenant },
      up.scopes == null ? {} : { "${prefix}_SCOPES" = up.scopes },
      up.issuer == null ? {} : { "${prefix}_ISSUER" = up.issuer },
      up.label == null ? {} : { "${prefix}_LABEL" = up.label },
      up.acr_values == null ? {} : { "${prefix}_ACR_VALUES" = up.acr_values },
      up.enabled ? {} : { "${prefix}_ENABLED" = "false" },
    )
  ])...)

  branding_vars = merge(
    var.branding.org_name == null ? {} : { UI_ORG_NAME = var.branding.org_name },
    var.branding.product_name == null ? {} : { UI_PRODUCT_NAME = var.branding.product_name },
    var.branding.title == null ? {} : { UI_TITLE = var.branding.title },
    var.branding.logo_url == null ? {} : { UI_LOGO_URL = var.branding.logo_url },
    var.branding.support_url == null ? {} : { UI_SUPPORT_URL = var.branding.support_url },
    var.branding.terms_url == null ? {} : { UI_TERMS_URL = var.branding.terms_url },
    var.branding.privacy_url == null ? {} : { UI_PRIVACY_URL = var.branding.privacy_url },
    var.branding.locale == null ? {} : { UI_LOCALE = var.branding.locale },
    var.branding.custom_css_url == null ? {} : { CUSTOM_CSS_REMOTE_URL = var.branding.custom_css_url },
    var.branding.whitelabel ? { UI_WHITELABEL = "true" } : {},
  )

  common_vars = merge(
    { LOG_LEVEL = var.log_level },
    local.upstream_vars,
    local.branding_vars,
    local.issuer == null ? {} : { SAG_ISSUER = local.issuer },
    {
      SESSION_SCOPE        = var.session.scope
      SUBJECT_TYPE         = var.session.subject_type
      CLIENTS_CIMD_ENABLED = tostring(var.clients.cimd_enabled)
    },
    var.otp.enabled ? {} : { OTP_ENABLED = "false" },
    length(var.otp.allowed_domains) == 0 ? {} : { OTP_ALLOWED_DOMAINS = join(",", var.otp.allowed_domains) },
    length(var.otp.blocked_domains) == 0 ? {} : { OTP_BLOCKED_DOMAINS = join(",", var.otp.blocked_domains) },
  )

  # SAG_SECRET and SUBJECT_SALT must be byte-identical across every block of an
  # instance, which is exactly why nothing in this module ever generates
  # either. SAG_SECRET_PREVIOUS is opt-in: SAG treats a secret reference it
  # cannot resolve as a hard start-up error, so naming it before the value
  # behind it exists would break the deployment rather than prepare it for
  # rotation.
  common_secret_names = concat(
    ["SAG_SECRET", "SUBJECT_SALT"],
    var.session.rotating ? ["SAG_SECRET_PREVIOUS"] : [],
    [for prefix, up in local.upstream_entries : "${prefix}_CLIENT_SECRET"],
  )

  # Instance-wide settings every block gets identically. Each submodule adds
  # its own backend selection on top; none of this is platform-specific.
  common = {
    sag_version  = var.sag_version
    issuer       = local.issuer
    vars         = local.common_vars
    secret_names = local.common_secret_names
    extra_vars   = var.extra_vars
    tags         = var.tags
  }
}

# Checked here rather than left to fail inside a submodule, because the message
# an operator needs names the shape of the instance file, not a resource.
resource "terraform_data" "instance_shape" {
  input = local.identity

  lifecycle {
    precondition {
      condition     = length(local.present) > 0
      error_message = "This instance declares no platform block. Set \"aws\", \"cloudflare\", or both: an instance with neither has nothing to deploy."
    }
    precondition {
      condition     = local.identity != null
      error_message = "This instance has no identity. Give it a \"domain\" - or, for a deployment with no DNS of its own, a \"name\" such as \"sandbox\", which keys the resource names the same way a domain would."
    }
    precondition {
      condition     = !local.domainless || local.sole
      error_message = "This instance has a \"name\" but no \"domain\", so its issuer comes from the URL its platform generates. That works for one block only, and this declares ${length(local.present)} (${join(", ", local.present)}). Give the instance a domain to run more than one."
    }
    precondition {
      condition     = !local.domainless || var.aws == null || var.aws.cdn == "none"
      error_message = "This instance has no \"domain\", so there is nothing for a CDN to serve: set aws.cdn to \"none\" and reach the deployment at its Function URL, or give the instance a domain."
    }
    precondition {
      condition     = !local.domainless || var.cloudflare == null
      error_message = "This instance has no \"domain\". A Worker has no usable generated hostname of its own to fall back on (workers.dev is off for a real deployment), so the cloudflare block needs one."
    }
    precondition {
      condition     = var.cloudflare == null || local.domainless || local.cloudflare_platform_domain != null
      error_message = "Block \"cloudflare\" needs its own platform_domain, because this instance declares more than one platform block (${join(", ", local.present)}) and they cannot all answer on ${coalesce(var.domain, "-")}."
    }
    precondition {
      condition     = var.aws == null || local.domainless || local.aws_platform_domain != null
      error_message = "Block \"aws\" needs its own platform_domain, because this instance declares more than one platform block (${join(", ", local.present)}) and they cannot all answer on ${coalesce(var.domain, "-")}."
    }
    precondition {
      condition     = local.cloudflare_platform_domain == null || local.aws_platform_domain == null || local.cloudflare_platform_domain != local.aws_platform_domain
      error_message = "Both platform blocks share platform_domain ${coalesce(local.aws_platform_domain, "-")}. Each block needs its own hostname to be independently reachable."
    }
  }
}

module "cloudflare" {
  source = "../cloudflare"
  count  = var.cloudflare == null ? 0 : 1

  slug            = local.cloudflare_slug
  platform_domain = local.cloudflare_platform_domain
  block           = var.cloudflare
  peer_jwks_urls  = local.cloudflare_peers
  common          = local.common
}

module "aws" {
  source = "../aws"
  count  = var.aws == null ? 0 : 1

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  slug            = local.aws_slug
  identity        = local.identity
  platform_domain = local.aws_platform_domain
  # Every ACM subject and CloudFront alias this block serves: its own hostname
  # first, then the central domain when that is a different name. DNS for the
  # central domain is deliberately not created - which platform answers on it
  # stays the operator's decision - so its ACM validation record only appears
  # if `extra_hosted_zone_ids` says where it lives.
  hostnames      = distinct(compact([local.aws_platform_domain, var.domain]))
  block          = var.aws
  peer_jwks_urls = local.aws_peers
  common         = local.common
}
