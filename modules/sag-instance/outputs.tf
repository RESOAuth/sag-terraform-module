output "identity" {
  description = "What every resource name is keyed off: the domain, or the name when there is none."
  value       = local.identity
}

output "issuer" {
  description = "SAG_ISSUER, identical on every block of this instance."
  value       = local.issuer
}

output "platform_domains" {
  description = "Each deployed block's own hostname, for machines."
  value = {
    for block, domain in {
      cloudflare = local.cloudflare_platform_domain
      aws        = local.aws_platform_domain
    } : block => domain if domain != null
  }
}

output "jwks_urls" {
  description = "Each deployed block's JWKS URL - what a sibling block, or a peer in another root configuration, lists as a peer."
  value = merge(
    length(module.cloudflare) == 0 ? {} : { cloudflare = module.cloudflare[0].jwks_url },
    length(module.aws) == 0 ? {} : { aws = module.aws[0].jwks_url },
  )
}

output "slugs" {
  description = "The per-block resource slug, for finding resources in a console."
  value = {
    for block, slug in {
      cloudflare = local.cloudflare_slug
      aws        = local.aws_slug
    } : block => slug if slug != null
  }
}

output "peer_jwks_urls" {
  description = "The mesh as computed, per block, so a split root configuration can be checked against the combined one."
  value = {
    for block, peers in {
      cloudflare = local.cloudflare_peers
      aws        = local.aws_peers
    } : block => peers if length(peers) > 0
  }
}

output "aws" {
  description = "The AWS block's own outputs, or null when this configuration deploys no AWS block."
  value       = length(module.aws) == 0 ? null : module.aws[0]
}

output "cloudflare" {
  description = "The Cloudflare block's own outputs, or null when this configuration deploys no Cloudflare block."
  value       = length(module.cloudflare) == 0 ? null : module.cloudflare[0]
}
