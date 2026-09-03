variable "slug" {
  type        = string
  description = "The shared fixed-length instance slug, from modules/sag-instance."
}

variable "platform_domain" {
  type        = string
  description = "The hostname this block answers on, attached to the main Worker as a custom domain."
}

variable "peer_jwks_urls" {
  type        = list(string)
  description = "The complete peer JWKS mesh for this block."
  default     = []
}

variable "block" {
  description = "The `cloudflare` object from modules/sag-instance's contract, unchanged."
  type = object({
    platform_domain     = optional(string)
    account_id          = string
    zone_id             = string
    state_store         = optional(string, "none")
    clients_store       = optional(string, "none")
    invocation_logs     = optional(bool, false)
    state_class_created = optional(bool, false)
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
  description = "Instance-wide settings shared by every platform block, rendered once by modules/sag-instance."
  type = object({
    sag_version  = string
    issuer       = optional(string)
    vars         = map(string)
    secret_names = list(string)
    extra_vars   = optional(map(string), {})
    tags         = optional(map(string), {})
  })
}

variable "compatibility_date" {
  type        = string
  default     = "2026-01-01"
  description = "Matches what smart-access-gateway's own adapters/cloudflare/wrangler.toml pins. Changing it is an upstream decision, not a per-instance one."
}
