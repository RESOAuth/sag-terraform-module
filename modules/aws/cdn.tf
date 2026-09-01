# ACM, CloudFront and Route 53.
#
# CloudFront is here purely for the custom domain and TLS - the same role
# Cloudflare's edge plays for a Worker. `cdn = "none"` skips all of it, for an
# instance putting a different CDN, or its own proxy, in front of the Function
# URL instead.

locals {
  # AWS managed policies, by their fixed well-known ids.
  #
  # CachingDisabled: an OIDC flow's cookies and query strings must reach the
  # function untouched. Caching any of it would be a correctness bug, not a
  # performance trade-off.
  caching_disabled_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  # AllViewerExceptHostHeader: a Lambda Function URL rejects a request whose
  # Host header is not its own, so the viewer's Host must not be forwarded. SAG
  # is unaffected because SAG_ISSUER is set explicitly and never derived from
  # the request - which is exactly why it is set explicitly.
  all_viewer_except_host_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"

  cdn_origin_id     = "sag-function-url"
  cdn_secret_header = "x-sag-origin-secret"

  function_url_host = trimsuffix(trimprefix(aws_lambda_function_url.sag.function_url, "https://"), "/")

  platform_zone_id = (
    !local.cdn_enabled ? null :
    var.block.hosted_zone_id != null ? var.block.hosted_zone_id :
    data.aws_route53_zone.platform[0].zone_id
  )

  # Which hostname's DNS this module can write. The block's own hostname always;
  # anything else - the central domain, typically, whose DNS may live on another
  # provider entirely - only when `extra_hosted_zone_ids` says where it lives.
  zone_for = local.cdn_enabled ? merge(
    { (var.platform_domain) = local.platform_zone_id },
    var.block.extra_hosted_zone_ids,
  ) : {}

  # Keys taken from a known list rather than from the certificate's own
  # validation options, so `for_each` stays resolvable on the plan that first
  # creates the certificate.
  validated_domains = [for host in var.hostnames : host if contains(keys(local.zone_for), host)]

  unvalidated_domains = [for host in var.hostnames : host if !contains(keys(local.zone_for), host)]

  # `aws_acm_certificate_validation` refuses to run unless the FQDNs it is
  # handed cover every subject on the certificate - which is correct, and means
  # it simply cannot be used when one subject's DNS lives outside this account.
  # The instance's central domain is exactly that case whenever a sibling
  # platform block, or another provider entirely, runs its DNS. So the wait is
  # skipped, the certificate ARN is taken directly, and the precondition on the
  # distribution below turns "certificate not issued yet" into a message naming
  # the records still to create rather than an opaque CloudFront error.
  wait_for_certificate = local.cdn_enabled && length(local.unvalidated_domains) == 0

  certificate_arn = (
    !local.cdn_enabled ? null :
    local.wait_for_certificate ? aws_acm_certificate_validation.sag[0].certificate_arn :
    aws_acm_certificate.sag[0].arn
  )
}

# A per-instance CloudFront-to-Function-URL header. Generated here, and in
# state, deliberately: SAG's own request handling never reads it (grep
# smart-access-gateway for CDN_ORIGIN_SECRET and there is nothing to find), so
# it constrains only what the CDN forwards, and compromising it lets someone
# skip the CDN and hit the Function URL directly - which is already possible,
# because the Function URL is deliberately public. `random_id` rather than
# `random_password` so the value is not marked sensitive and the rest of the
# environment stays legible in a plan. That is the right way round for this one
# value and nowhere else in this module.
resource "random_id" "cdn_origin_secret" {
  count       = local.cdn_enabled ? 1 : 0
  byte_length = 32
}

data "aws_route53_zone" "platform" {
  count = local.cdn_enabled && var.block.hosted_zone_id == null ? 1 : 0

  # Exact zone name. Defaults to the block's own hostname, which is right when
  # the hostname is itself a delegated zone; set `hosted_zone_name` when the
  # record lives in a parent zone instead, and `hosted_zone_id` to skip the
  # lookup entirely.
  name         = coalesce(var.block.hosted_zone_name, var.platform_domain)
  private_zone = false
}

# --- ACM --------------------------------------------------------------------

resource "aws_acm_certificate" "sag" {
  count    = local.cdn_enabled ? 1 : 0
  provider = aws.us_east_1

  domain_name               = var.hostnames[0]
  subject_alternative_names = slice(var.hostnames, 1, length(var.hostnames))
  validation_method         = "DNS"
  tags                      = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = { for host in local.validated_domains : host => host }

  zone_id = local.zone_for[each.key]
  name    = one([for dvo in aws_acm_certificate.sag[0].domain_validation_options : dvo.resource_record_name if dvo.domain_name == each.key])
  type    = one([for dvo in aws_acm_certificate.sag[0].domain_validation_options : dvo.resource_record_type if dvo.domain_name == each.key])
  records = [one([for dvo in aws_acm_certificate.sag[0].domain_validation_options : dvo.resource_record_value if dvo.domain_name == each.key])]
  ttl     = 300

  # ACM reuses one validation record for two names in the same zone, and a
  # re-request after an interrupted apply must overwrite rather than collide.
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "sag" {
  count    = local.wait_for_certificate ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.sag[0].arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]

  timeouts {
    create = "30m"
  }
}

# --- CloudFront -------------------------------------------------------------

resource "aws_cloudfront_distribution" "sag" {
  # checkov:skip=CKV_AWS_86:Access logging needs a bucket and an ownership-controls dance, and would record every sign-in request's path. Worth turning on deliberately for a production instance; not worth turning on silently for every instance.
  # checkov:skip=CKV_AWS_305:A default root object is for a static site. Every path here is an OIDC endpoint, and "/" is SAG's own.
  # checkov:skip=CKV_AWS_310:Origin failover needs a second origin. There is one function, and a second one would need its own state and its own signing key to be useful.
  # checkov:skip=CKV_AWS_374:An identity provider that geo-restricts is an identity provider that locks people out when they travel.
  # checkov:skip=CKV2_AWS_32:SAG sets its own security response headers, including the CSP its own UI needs. A CloudFront policy on top would either duplicate them or fight them.
  # checkov:skip=CKV2_AWS_47:The Log4j managed rule protects a Java library. SAG is Node.js and bundles no Java at all.
  count = local.cdn_enabled ? 1 : 0

  enabled         = true
  comment         = "SAG ${var.hostnames[0]}, managed by the SAG Terraform module"
  aliases         = var.hostnames
  http_version    = "http2and3"
  is_ipv6_enabled = true
  price_class     = "PriceClass_All"
  web_acl_id      = local.cdn_enabled && var.block.waf.create ? aws_wafv2_web_acl.sag[0].arn : null

  origin {
    origin_id   = local.cdn_origin_id
    domain_name = local.function_url_host

    custom_header {
      name  = local.cdn_secret_header
      value = random_id.cdn_origin_secret[0].b64_url
    }

    custom_origin_config {
      http_port  = 80
      https_port = 443
      # The Function URL is TLS and there is no reason to allow less.
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }
  }

  default_cache_behavior {
    target_origin_id       = local.cdn_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"]
    cached_methods         = ["HEAD", "GET"]
    compress               = true

    cache_policy_id          = local.caching_disabled_policy_id
    origin_request_policy_id = local.all_viewer_except_host_policy_id
  }

  viewer_certificate {
    acm_certificate_arn      = local.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = local.tags

  lifecycle {
    precondition {
      condition = local.wait_for_certificate || aws_acm_certificate.sag[0].status == "ISSUED"
      error_message = join("\n", concat(
        [
          "The certificate for this instance is not ISSUED, and this module was given no hosted zone for:",
          "",
        ],
        [for host in local.unvalidated_domains : "  ${host}"],
        [
          "",
          "ACM will not issue until each of those has its validation CNAME created by whoever runs",
          "its DNS. Create the records in the certificate_validation_records output, or add the zone",
          "to aws.extra_hosted_zone_ids to have Terraform create them, then apply again.",
        ],
      ))
    }
  }
}

# --- Route 53 ---------------------------------------------------------------
#
# Only for the block's own hostname. Which platform answers on the instance's
# central domain stays the operator's decision, so no record is created for it
# even when this module knows its zone - that zone is used for the certificate's
# validation record and nothing else.

resource "aws_route53_record" "platform" {
  for_each = local.cdn_enabled ? toset(["A", "AAAA"]) : toset([])

  zone_id = local.platform_zone_id
  name    = var.platform_domain
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.sag[0].domain_name
    zone_id                = aws_cloudfront_distribution.sag[0].hosted_zone_id
    evaluate_target_health = false
  }
}
