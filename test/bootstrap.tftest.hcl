# Leave external and archive real: the deliberately missing release path must
# never be reached by the zone-only bootstrap target.
mock_provider "aws" {
  source = "./mocks/aws"
}
mock_provider "aws" {
  alias  = "us_east_1"
  source = "./mocks/aws"
}
mock_provider "cloudflare" {}

run "zone_bootstrap_does_not_fetch_release_or_wait_for_certificate" {
  command = apply

  module {
    source = "../modules/aws"
  }

  plan_options {
    target = [aws_route53_zone.platform[0]]
  }

  variables {
    slug            = "awseuwest2-test"
    identity        = "id.example.com"
    platform_domain = "aws-eu-west-2.id.example.com"
    hostnames       = ["aws-eu-west-2.id.example.com"]
    block = {
      region              = "eu-west-2"
      platform_domain     = "aws-eu-west-2.id.example.com"
      create_hosted_zone  = true
      serve_issuer_domain = false
      require_secrets     = false
    }
    common = {
      sag_version  = "file:/sag-bootstrap-must-not-fetch-a-release"
      issuer       = "https://id.example.com"
      vars         = { SAG_ISSUER = "https://id.example.com" }
      secret_names = ["SAG_SECRET", "SUBJECT_SALT"]
    }
  }

  override_resource {
    target          = aws_route53_zone.platform[0]
    override_during = plan
    values = {
      id                  = "ZBOOTSTRAPPLATFORM"
      zone_id             = "ZBOOTSTRAPPLATFORM"
      arn                 = "arn:aws:route53:::hostedzone/ZBOOTSTRAPPLATFORM"
      primary_name_server = "ns-1.example.org"
      name_servers        = ["ns-1.example.org", "ns-2.example.net"]
    }
  }

  assert {
    condition = alltrue([
      aws_route53_zone.platform[0].name == "aws-eu-west-2.id.example.com",
      output.hosted_zone_delegation.zone_id == "ZBOOTSTRAPPLATFORM",
      output.hosted_zone_delegation.records == tolist(["ns-1.example.org", "ns-2.example.net"]),
    ])
    error_message = "The zone-only target must expose delegation details without preparing the application or certificate."
  }
}

run "composed_zone_bootstrap_exposes_delegation" {
  command = apply

  plan_options {
    target = [module.sag.module.aws[0].aws_route53_zone.platform[0]]
  }

  variables {
    instance = {
      domain      = "id.example.com"
      sag_version = "file:/sag-bootstrap-must-not-fetch-a-release"
      aws = {
        region              = "eu-west-2"
        platform_domain     = "aws-eu-west-2.id.example.com"
        create_hosted_zone  = true
        serve_issuer_domain = false
        require_secrets     = false
      }
    }
  }

  override_resource {
    target          = module.sag.module.aws[0].aws_route53_zone.platform[0]
    override_during = plan
    values = {
      id                  = "ZBOOTSTRAPPLATFORM"
      zone_id             = "ZBOOTSTRAPPLATFORM"
      arn                 = "arn:aws:route53:::hostedzone/ZBOOTSTRAPPLATFORM"
      primary_name_server = "ns-1.example.org"
      name_servers        = ["ns-1.example.org", "ns-2.example.net"]
    }
  }

  assert {
    condition = alltrue([
      output.hosted_zone_id == "ZBOOTSTRAPPLATFORM",
      output.hosted_zone_name_servers == tolist(["ns-1.example.org", "ns-2.example.net"]),
      output.hosted_zone_delegation.zone_id == "ZBOOTSTRAPPLATFORM",
      output.hosted_zone_delegation.records == tolist(["ns-1.example.org", "ns-2.example.net"]),
    ])
    error_message = "The composed module must expose delegation details after targeting only the platform zone."
  }
}
