# The contract a root configuration's `.tfvars.json` files target: one file per
# instance, and these are the keys it may set. Note `sag_version` rather than
# `version`, because Terraform reserves `version` as a module meta-argument and
# refuses to accept an input variable by that name.
#
# Nothing here has a default that is a secret value, and nothing here accepts a
# session- or encryption-relevant secret at all - not even an upstream's
# `client_secret`. Every one of those is set out-of-band with
# scripts/sag-secrets.mjs, so keeping a field for one would only invite a real
# secret into a git-tracked instance file, which is the one thing this design
# exists to prevent. See docs/aws-secret-references.md.

variable "domain" {
  type        = string
  default     = null
  description = <<-EOT
    The central issuer identity. Becomes SAG_ISSUER on every platform block.
    Omit only for a domainless deployment, which uses `name` instead.
  EOT

  validation {
    condition     = var.domain == null || can(regex("^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", lower(var.domain)))
    error_message = "domain must be a dotted hostname, e.g. \"acme.example.com\"."
  }
}

variable "name" {
  type        = string
  default     = null
  description = <<-EOT
    Stable identity for an instance with no domain of its own. Keys every
    resource name exactly as `domain` otherwise would. Requires a single block
    reachable at a platform-generated URL.
  EOT

  validation {
    condition     = var.name == null || can(regex("^[a-z][a-z0-9-]{0,30}$", var.name))
    error_message = "name must be lower-case alphanumeric with hyphens, starting with a letter, at most 31 characters."
  }
}

variable "sag_version" {
  type        = string
  default     = "latest"
  description = <<-EOT
    Which smart-access-gateway source to deploy: "latest", "bleeding-edge"
    (the current main branch), a pinned release tag such as "v1.4.0", or
    "file:<absolute path>" for a local checkout.

    The AWS path needs a source carrying the `aws:ssm:` indirect-secret
    mechanism, or the Lambda receives its pointers as literal secrets and the
    deployment is quietly wrong rather than broken. That mechanism is on main
    but is not in a published release yet, so "bleeding-edge" is currently the
    lowest-risk choice for an AWS block and "latest" is not usable at all -
    GitHub excludes pre-releases from "latest", and every release so far is one.
    Pin a real tag as soon as one carries it.

    `file:` builds from a working tree, for developing against an unmerged
    change. It is deliberately not reproducible; the resolved commit and
    whether the tree was dirty are reported in the plan and in the `release`
    output, so a deployment built that way says so.
  EOT

  validation {
    condition     = can(regex("^(latest|bleeding-edge|v?[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?|file:/.+)$", var.sag_version))
    error_message = "sag_version must be \"latest\", \"bleeding-edge\", a release tag such as \"v1.4.0\", or \"file:<absolute path>\"."
  }
}

variable "branding" {
  description = "UI_* variables. Purely cosmetic; none of it changes behaviour."
  type = object({
    org_name       = optional(string)
    product_name   = optional(string)
    title          = optional(string)
    logo_url       = optional(string)
    support_url    = optional(string)
    terms_url      = optional(string)
    privacy_url    = optional(string)
    locale         = optional(string)
    whitelabel     = optional(bool, false)
    custom_css_url = optional(string)
  })
  default = {}
}

variable "session" {
  description = <<-EOT
    Session shape. `rotating` adds SAG_SECRET_PREVIOUS to the environment as a
    second `aws:ssm:` pointer; leave it false until that parameter exists,
    because SAG treats a pointer it cannot resolve as a hard start-up error
    rather than an absent variable.
  EOT
  type = object({
    scope        = optional(string, "shared")
    subject_type = optional(string, "public")
    rotating     = optional(bool, false)
  })
  default = {}

  validation {
    condition     = contains(["shared", "rp"], var.session.scope)
    error_message = "session.scope must be \"shared\" or \"rp\"."
  }
  validation {
    condition     = contains(["public", "pairwise"], var.session.subject_type)
    error_message = "session.subject_type must be \"public\" or \"pairwise\"."
  }
}

variable "upstreams" {
  description = <<-EOT
    Upstream IdPs. Each renders UPSTREAM_<PROVIDER>_<SLUG>_* variables, where
    SLUG is the punctuation-stripped upper-cased email domain, or COMMON for
    the catch-all.

    An upstream's client secret is deliberately not part of this contract. It
    is set out-of-band with scripts/sag-secrets.mjs, and the corresponding
    UPSTREAM_*_CLIENT_SECRET is always an `aws:ssm:` pointer on AWS and a
    write-only Workers secret on Cloudflare.
  EOT
  type = list(object({
    provider   = string
    domain     = optional(string)
    client_id  = string
    scopes     = optional(string)
    issuer     = optional(string)
    tenant     = optional(string)
    label      = optional(string)
    acr_values = optional(string)
    enabled    = optional(bool, true)
  }))
  default = []

  validation {
    condition     = alltrue([for up in var.upstreams : can(regex("^[a-z][a-z0-9-]*$", up.provider))])
    error_message = "each upstream provider must be lower-case alphanumeric with hyphens, e.g. \"microsoft\"."
  }
}

variable "clients" {
  description = "Relying-party registration behaviour."
  type = object({
    cimd_enabled = optional(bool, true)
  })
  default = {}
}

variable "otp" {
  description = <<-EOT
    The email code fallback. Disabling it with no upstreams configured is a
    start-up error in SAG, not something this module can catch.
  EOT
  type = object({
    enabled         = optional(bool, true)
    allowed_domains = optional(list(string), [])
    blocked_domains = optional(list(string), [])
  })
  default = {}
}

variable "log_level" {
  type    = string
  default = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of debug, info, warn, error."
  }
}

variable "extra_vars" {
  description = <<-EOT
    Escape hatch: non-secret SAG environment variables applied to every block,
    for anything this contract does not model yet. A block's own `extra_vars`
    overrides these.
  EOT
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags merged onto every taggable resource, on top of the module's own."
  type        = map(string)
  default     = {}
}

variable "cloudflare" {
  description = <<-EOT
    The Cloudflare Workers block. Null deploys nothing on Cloudflare, and the
    submodule is not instantiated at all, so a root configuration carrying no
    Cloudflare credentials is unaffected by its presence in this module.

    `state_class_created` is a two-phase apply, like `aws.require_secrets` but
    the other way round: false creates the Durable Object namespace, true
    leaves it alone. Set it true once the first apply has succeeded. With it
    left false, Cloudflare rejects every later upload of the main Worker,
    because the migration carries no `old_tag` to verify against the `v1`
    already deployed.
  EOT
  type = object({
    platform_domain = optional(string)
    account_id      = string
    zone_id         = string
    state_store     = optional(string, "none")
    clients_store   = optional(string, "none")
    invocation_logs = optional(bool, false)
    # The "already created" half of a two-phase apply, the same shape
    # aws.require_secrets has and for the same kind of reason: creating the
    # Durable Object namespace and leaving it alone afterwards are different
    # requests, and nothing in a configuration can tell Terraform which apply
    # it is on. Leave it false for the first apply of a state_store =
    # "durable-object" block, then set it true and leave it true.
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
  default = null

  validation {
    condition     = var.cloudflare == null || contains(["durable-object", "none"], var.cloudflare.state_store)
    error_message = "cloudflare.state_store must be \"durable-object\" or \"none\"."
  }
  validation {
    condition     = var.cloudflare == null || contains(["kv", "none"], var.cloudflare.clients_store)
    error_message = "cloudflare.clients_store must be \"kv\" or \"none\"."
  }
}

variable "aws" {
  description = <<-EOT
    The AWS Lambda block. Null deploys nothing on AWS.

    `require_secrets` is the "blocked" gate, expressed as a plan-time
    precondition: with it on, a plan fails and names any secret this
    instance's configuration implies whose SSM parameter does not exist
    yet. Turn it off for the first apply of a brand-new instance - the
    per-instance KMS key that `sag-secrets` writes under does not exist
    until something has been applied - then turn it back on.
  EOT
  type = object({
    platform_domain    = optional(string)
    region             = string
    state_store        = optional(string, "none")
    clients_store      = optional(string, "none")
    cdn                = optional(string, "cloudfront")
    hosted_zone_id     = optional(string)
    hosted_zone_name   = optional(string)
    memory_mb          = optional(number, 512)
    timeout_seconds    = optional(number, 15)
    log_retention_days = optional(number, 30)
    runtime            = optional(string, "nodejs22.x")
    architecture       = optional(string, "arm64")
    require_secrets    = optional(bool, true)
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
    # Zones for ACM DNS validation records of hostnames outside the block's own
    # zone - the central `domain`, typically, when its DNS lives elsewhere.
    # A hostname with no entry here gets no validation record from Terraform and
    # is reported in the `certificate_validation_records` output instead.
    extra_hosted_zone_ids = optional(map(string), {})
    peer_jwks_urls        = optional(list(string), [])
    extra_vars            = optional(map(string), {})
  })
  default = null

  validation {
    condition     = var.aws == null || can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws.region))
    error_message = "aws.region must look like \"eu-west-2\"."
  }
  validation {
    condition     = var.aws == null || contains(["dynamo-db", "none"], var.aws.state_store)
    error_message = "aws.state_store must be \"dynamo-db\" or \"none\"."
  }
  validation {
    condition     = var.aws == null || contains(["s3", "none"], var.aws.clients_store)
    error_message = "aws.clients_store must be \"s3\" or \"none\"."
  }
  validation {
    condition     = var.aws == null || contains(["cloudfront", "none"], var.aws.cdn)
    error_message = "aws.cdn must be \"cloudfront\" or \"none\"."
  }
  validation {
    condition     = var.aws == null || contains(["arm64", "x86_64"], var.aws.architecture)
    error_message = "aws.architecture must be \"arm64\" or \"x86_64\"."
  }
  validation {
    condition     = var.aws == null || can(regex("^nodejs[0-9]+\\.x$", var.aws.runtime))
    error_message = "aws.runtime must be a Node.js Lambda runtime such as \"nodejs22.x\"; SAG needs Node 20 or newer."
  }
}
