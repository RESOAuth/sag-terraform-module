# The root configuration `terraform test` runs the .tftest.hcl files in this
# directory against.
#
# It exists only so the tests have a root module to plan; it deploys nothing and
# reaches no provider, because every test file replaces all five providers with
# mocks from ./mocks. Run the suite with:
#
#   cd test && terraform init && terraform test
#
# Variables are declared loosely and forwarded straight through, exactly as a
# real root configuration does: the type constraints,
# defaults and validation all live in modules/sag-instance/variables.tf, and a
# second copy of them here would only be somewhere for the two to disagree.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 5.5"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}

provider "aws" {
  region = "eu-west-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

provider "cloudflare" {}

# One variable, rather than the fifteen a real root configuration declares, so a
# fixture in test/fixtures/ can be handed over whole:
#
#   variables { instance = jsondecode(file("fixtures/single-aws.json")) }
#
# The `.tfvars.json` shape a root configuration actually uses is proved by a
# real deployment instead - see AGENTS.md - not here.
variable "instance" {
  type    = any
  default = {}
}

module "sag" {
  source = "../modules/sag-instance"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
    cloudflare    = cloudflare
  }

  # try() rather than lookup(): var.instance is `any`, so a key the fixture
  # omits is an error to reference rather than a null to default.
  domain      = try(var.instance.domain, null)
  name        = try(var.instance.name, null)
  sag_version = try(var.instance.sag_version, "latest")
  log_level   = try(var.instance.log_level, "info")
  branding    = try(var.instance.branding, {})
  session     = try(var.instance.session, {})
  clients     = try(var.instance.clients, {})
  otp         = try(var.instance.otp, {})
  upstreams   = try(var.instance.upstreams, [])
  extra_vars  = try(var.instance.extra_vars, {})
  tags        = try(var.instance.tags, {})
  aws         = try(var.instance.aws, null)
  cloudflare  = try(var.instance.cloudflare, null)
}

# Surfaced so the test files can assert on the rendered environment and the
# resource set without reaching into module internals.
output "slugs" {
  value = module.sag.slugs
}

output "issuer" {
  value = module.sag.issuer
}

output "platform_domains" {
  value = module.sag.platform_domains
}

output "peer_jwks_urls" {
  value = module.sag.peer_jwks_urls
}

output "aws_block" {
  value = module.sag.aws
}

output "cloudflare_block" {
  value = module.sag.cloudflare
}
