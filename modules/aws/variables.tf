# Inputs to the AWS platform block.
#
# `slug` and `common` are computed once by modules/sag-instance and passed down,
# so both platform submodules agree on them by construction rather than by
# reimplementing the same derivation twice.

variable "slug" {
  type        = string
  description = "The shared fixed-length instance slug, from modules/sag-instance."
}

variable "identity" {
  type        = string
  description = "The instance's central identity - its domain, or its name when it has none. Tagged onto resources so the console shows what a hashed slug belongs to."
}

variable "platform_domain" {
  type        = string
  description = "The hostname this block answers on. Null for a domainless instance, which is reachable only at its Function URL and therefore requires cdn = \"none\"."
}

variable "hostnames" {
  type        = list(string)
  description = "Every hostname this block's certificate and CDN serve: platform_domain first, then the central domain when that differs."
}

variable "peer_jwks_urls" {
  type        = list(string)
  description = "The complete peer JWKS mesh for this block."
  default     = []
}

variable "block" {
  description = "The `aws` object from modules/sag-instance's contract, unchanged."
  type = object({
    platform_domain       = optional(string)
    region                = string
    state_store           = optional(string, "none")
    clients_store         = optional(string, "none")
    cdn                   = optional(string, "cloudfront")
    hosted_zone_id        = optional(string)
    hosted_zone_name      = optional(string)
    memory_mb             = optional(number, 512)
    timeout_seconds       = optional(number, 15)
    log_retention_days    = optional(number, 30)
    runtime               = optional(string, "nodejs22.x")
    architecture          = optional(string, "arm64")
    require_secrets       = optional(bool, true)
    extra_hosted_zone_ids = optional(map(string), {})
    waf = optional(object({
      create     = optional(bool, false)
      rate_limit = optional(number, 300)
    }), {})
    email = optional(object({
      provider           = string
      from               = optional(string)
      region             = optional(string)
      reply_to           = optional(string)
      subject            = optional(string)
      notify_template_id = optional(string)
      configuration_set  = optional(string)
      destination        = optional(string)
    }))
    peer_jwks_urls = optional(list(string), [])
    extra_vars     = optional(map(string), {})
  })
}

variable "common" {
  description = <<-EOT
    Instance-wide settings shared by every platform block, rendered once by
    modules/sag-instance so two platforms cannot disagree about a SAG variable
    name or value format.

    `vars` is every SAG environment variable that is not platform-specific;
    `secret_names` is every secret the instance implies before this block adds
    its own email provider's.
  EOT
  type = object({
    sag_version  = string
    issuer       = optional(string)
    vars         = map(string)
    secret_names = list(string)
    extra_vars   = optional(map(string), {})
    tags         = optional(map(string), {})
  })
}
