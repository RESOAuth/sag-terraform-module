terraform {
  required_version = ">= 1.6.0"

  required_providers {
    # `aws.us_east_1` is a configuration alias rather than a second provider
    # because ACM certificates for CloudFront and CLOUDFRONT-scoped WAF Web
    # ACLs only exist in us-east-1, whatever region the function runs in.
    #
    # A root configuration that deploys only the Cloudflare block still has to
    # supply both: Terraform requires a provider configuration for every child
    # module that declares one, even when `count = 0` means nothing in that
    # module is ever created and the provider is therefore never authenticated.
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 6.0"
      configuration_aliases = [aws.us_east_1]
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
