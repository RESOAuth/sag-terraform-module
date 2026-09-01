output "platform_domain" {
  description = "The hostname this block answers on."
  value       = var.platform_domain
}

output "slug" {
  description = "The instance slug every resource name in this block derives from."
  value       = var.slug
}

output "issuer" {
  description = "SAG_ISSUER as deployed."
  value       = var.common.issuer
}

output "jwks_url" {
  description = <<-EOT
    This block's JWKS URL, which a sibling block lists as a peer. Null for a
    domainless instance, which has no hostname of its own for a peer to fetch.
  EOT
  value       = var.platform_domain == null ? null : "https://${var.platform_domain}/.well-known/jwks.json"
}

output "function_name" {
  value = aws_lambda_function.sag.function_name
}

output "function_arn" {
  value = aws_lambda_function.sag.arn
}

output "function_url" {
  description = "The Function URL, which is public by design. Behind the CDN in an ordinary deployment; the only endpoint when cdn = \"none\"."
  value       = aws_lambda_function_url.sag.function_url
}

output "role_arn" {
  value = aws_iam_role.exec.arn
}

output "signing_key_arn" {
  value = aws_kms_key.signing.arn
}

output "secrets_key_alias" {
  description = "The KMS alias scripts/sag-secrets.mjs writes SecureString parameters under."
  value       = aws_kms_alias.secrets.name
}

output "secrets_path" {
  description = "The SSM path this instance's secrets live under. Terraform writes no parameter here; only the pointers that name them."
  value       = "${local.secrets_prefix}/"
}

output "secret_names" {
  description = "Every secret this instance's configuration implies, whether or not it has been set yet."
  value       = local.secret_names
}

output "missing_secrets" {
  description = "Secrets named in the environment whose SSM parameter does not exist. Non-empty means SAG will fail to start."
  value       = local.missing_secrets
}

output "release" {
  description = "What version resolved to, so a plan or apply log records which code went out."
  value = {
    requested = var.common.sag_version
    tag       = data.external.release.result.tag
    commit    = data.external.release.result.commit
    source    = data.external.release.result.source
  }
}

output "distribution_id" {
  value = local.cdn_enabled ? aws_cloudfront_distribution.sag[0].id : null
}

output "distribution_domain_name" {
  value = local.cdn_enabled ? aws_cloudfront_distribution.sag[0].domain_name : null
}

output "certificate_arn" {
  value = local.cdn_enabled ? aws_acm_certificate.sag[0].arn : null
}

output "unvalidated_domains" {
  description = <<-EOT
    Certificate subjects whose DNS this module was given no zone for. ACM will
    not issue until each has its validation CNAME created by hand, or by
    whoever runs its DNS. Add the zone to aws.extra_hosted_zone_ids to have
    Terraform create the record instead.
  EOT
  value       = local.unvalidated_domains
}

output "certificate_validation_records" {
  description = "Every validation CNAME ACM asked for, including the ones this module did not create."
  value = local.cdn_enabled ? [
    for dvo in aws_acm_certificate.sag[0].domain_validation_options : {
      domain  = dvo.domain_name
      name    = dvo.resource_record_name
      type    = dvo.resource_record_type
      value   = dvo.resource_record_value
      created = contains(local.validated_domains, dvo.domain_name)
    }
  ] : []
}

output "environment" {
  description = <<-EOT
    The Lambda's whole environment as rendered. Every session- or
    encryption-relevant secret in it is an `aws:ssm:` pointer rather than a
    value, which is why this is safe to output and useful to review - the one
    real secret here, CDN_ORIGIN_SECRET, protects nothing SAG itself checks.
  EOT
  value       = local.environment
}

output "resources" {
  description = <<-EOT
    What this block manages, entirely known at plan time. A resource's id is
    not knowable before it exists, but its name is - that is the whole point of
    deriving every name from the domain - so this is the reviewable summary of
    the resource set, and what test/render.tftest.hcl asserts against.
  EOT
  value = {
    function            = local.names.function
    role                = local.names.role
    log_group           = local.names.log_group
    signing_key_alias   = local.names.signing_alias
    secrets_key_alias   = local.names.secrets_alias
    state_table         = var.block.state_store == "dynamo-db" ? local.names.state_table : null
    clients_bucket      = var.block.clients_store == "s3" ? local.names.clients_bucket : null
    waf_acl             = local.cdn_enabled && var.block.waf.create ? local.names.waf_acl : null
    cdn                 = local.cdn_enabled
    certificate_domains = local.cdn_enabled ? var.hostnames : []
    dns_records         = local.cdn_enabled ? [for type in ["A", "AAAA"] : "${var.platform_domain} ${type}"] : []
  }
}
