# The optional Web ACL.
#
# A rate-based rule on /authorize and its sub-paths, matching what
# smart-access-gateway's own deployment.md already recommends doing by hand.
# CLOUDFRONT-scoped Web ACLs exist only in us-east-1, whatever region the
# function runs in.

resource "aws_wafv2_web_acl" "sag" {
  # checkov:skip=CKV_AWS_192:The Log4j managed rule protects a Java library. SAG is Node.js.
  # checkov:skip=CKV2_AWS_31:WAF logging needs a Kinesis Firehose or a log group and bills per request. This ACL exists for one rate-limit rule, whose blocks are already visible in its CloudWatch metrics.
  count    = local.cdn_enabled && var.block.waf.create ? 1 : 0
  provider = aws.us_east_1

  name        = local.names.waf_acl
  description = "SAG rate limiting, managed by the SAG Terraform module"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "authorize-rate-limit"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.block.waf.rate_limit
        aggregate_key_type = "IP"

        # Scoped down so the limit applies to starting a sign-in, not to every
        # request: discovery and JWKS are fetched far more often, by machines
        # that would trip a per-IP limit legitimately.
        scope_down_statement {
          byte_match_statement {
            positional_constraint = "STARTS_WITH"
            search_string         = "/authorize"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "authorize-rate-limit"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = local.names.waf_acl
  }

  tags = local.tags
}
