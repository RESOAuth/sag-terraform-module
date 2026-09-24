mock_provider "aws" {
  source = "./mocks/aws"
}
mock_provider "aws" {
  alias  = "us_east_1"
  source = "./mocks/aws"
}
mock_provider "cloudflare" {}
mock_provider "archive" {
  source = "./mocks/archive"
}
mock_provider "external" {
  source = "./mocks/external"
}
mock_provider "random" {
  source = "./mocks/random"
}

run "created_zone_wires_validation_and_platform_records" {
  command = plan

  module {
    source = "../modules/aws"
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
      sag_version  = "latest"
      issuer       = "https://id.example.com"
      vars         = { SAG_ISSUER = "https://id.example.com" }
      secret_names = ["SAG_SECRET", "SUBJECT_SALT"]
    }
  }

  override_resource {
    target          = aws_route53_zone.platform[0]
    override_during = plan
    values = {
      zone_id      = "ZCREATEDPLATFORM"
      name_servers = ["ns-2.example.net", "ns-1.example.org"]
    }
  }

  assert {
    condition = alltrue([
      length(data.aws_route53_zone.platform) == 0,
      aws_route53_zone.platform[0].name == "aws-eu-west-2.id.example.com",
      length(aws_route53_zone.platform[0].vpc) == 0,
      aws_route53_zone.platform[0].tags["ManagedBy"] == "sag",
      output.hosted_zone_id == "ZCREATEDPLATFORM",
      output.resources.hosted_zone == "aws-eu-west-2.id.example.com",
    ])
    error_message = "Creating a platform zone must replace the existing-zone lookup and expose its identity."
  }

  assert {
    condition = alltrue([
      toset(aws_cloudfront_distribution.sag[0].aliases) == toset(["aws-eu-west-2.id.example.com"]),
      aws_acm_certificate.sag[0].domain_name == "aws-eu-west-2.id.example.com",
      length(aws_acm_certificate.sag[0].subject_alternative_names) == 0,
      aws_route53_record.certificate_validation["aws-eu-west-2.id.example.com"].zone_id == "ZCREATEDPLATFORM",
      aws_route53_record.platform["A"].zone_id == "ZCREATEDPLATFORM",
      aws_route53_record.platform["AAAA"].zone_id == "ZCREATEDPLATFORM",
      aws_route53_record.platform["A"].name == "aws-eu-west-2.id.example.com",
      aws_route53_record.platform["AAAA"].name == "aws-eu-west-2.id.example.com",
    ])
    error_message = "ACM validation and both CloudFront aliases must use the newly created platform zone."
  }

  assert {
    condition = jsonencode(output.hosted_zone_delegation) == jsonencode({
      zone_id = "ZCREATEDPLATFORM"
      name    = "aws-eu-west-2.id.example.com"
      type    = "NS"
      ttl     = 300
      records = ["ns-1.example.org", "ns-2.example.net"]
    }) && output.hosted_zone_name_servers == tolist(["ns-1.example.org", "ns-2.example.net"])
    error_message = "The delegation output must contain the complete parent NS record with stable nameserver ordering."
  }
}

run "platform_only_alias_preserves_shared_issuer" {
  command = plan

  variables {
    instance = {
      domain = "id.example.com"
      aws = {
        region              = "eu-west-2"
        platform_domain     = "aws-eu-west-2.id.example.com"
        hosted_zone_id      = "ZEXISTINGPLATFORM"
        serve_issuer_domain = false
        require_secrets     = false
      }
    }
  }

  assert {
    condition = alltrue([
      output.issuer == "https://id.example.com",
      output.aws_block.environment["SAG_ISSUER"] == "https://id.example.com",
      output.aws_block.resources.certificate_domains == tolist(["aws-eu-west-2.id.example.com"]),
      output.aws_block.hosted_zone_id == "ZEXISTINGPLATFORM",
      output.aws_block.hosted_zone_delegation == null,
      output.aws_block.hosted_zone_name_servers == null,
      output.aws_block.resources.hosted_zone == null,
      length(output.aws_block.unvalidated_domains) == 0,
    ])
    error_message = "Platform-only serving must remove the issuer alias without changing SAG_ISSUER or managing the supplied zone."
  }
}

run "defaults_keep_issuer_alias_and_zone_lookup" {
  command = plan

  variables {
    instance = {
      domain = "id.example.com"
      aws = {
        region                = "eu-west-2"
        platform_domain       = "aws-eu-west-2.id.example.com"
        extra_hosted_zone_ids = { "id.example.com" = "ZISSUER" }
        require_secrets       = false
      }
    }
  }

  assert {
    condition = alltrue([
      output.aws_block.resources.certificate_domains == tolist(["aws-eu-west-2.id.example.com", "id.example.com"]),
      output.aws_block.hosted_zone_id == "ZTESTTESTTESTTESTTEST",
      output.aws_block.hosted_zone_delegation == null,
      output.aws_block.resources.hosted_zone == null,
    ])
    error_message = "Omitting the new options must retain the issuer alias and lookup of an existing public zone."
  }
}

run "zone_creation_rejects_existing_id" {
  command = plan

  module {
    source = "../modules/sag-instance"
  }

  variables {
    domain = "id.example.com"
    aws = {
      region             = "eu-west-2"
      platform_domain    = "aws-eu-west-2.id.example.com"
      create_hosted_zone = true
      hosted_zone_id     = "ZEXISTINGPLATFORM"
      require_secrets    = false
    }
  }

  expect_failures = [var.aws]
}

run "zone_creation_rejects_existing_name" {
  command = plan

  module {
    source = "../modules/sag-instance"
  }

  variables {
    domain = "id.example.com"
    aws = {
      region             = "eu-west-2"
      platform_domain    = "aws-eu-west-2.id.example.com"
      create_hosted_zone = true
      hosted_zone_name   = "example.com"
      require_secrets    = false
    }
  }

  expect_failures = [var.aws]
}

run "zone_creation_requires_explicit_platform_domain" {
  command = plan

  module {
    source = "../modules/sag-instance"
  }

  variables {
    domain = "id.example.com"
    aws = {
      region             = "eu-west-2"
      create_hosted_zone = true
      require_secrets    = false
    }
  }

  expect_failures = [var.aws]
}

run "zone_creation_requires_cloudfront" {
  command = plan

  module {
    source = "../modules/sag-instance"
  }

  variables {
    domain = "id.example.com"
    aws = {
      region             = "eu-west-2"
      platform_domain    = "aws-eu-west-2.id.example.com"
      create_hosted_zone = true
      cdn                = "none"
      require_secrets    = false
    }
  }

  expect_failures = [var.aws]
}
