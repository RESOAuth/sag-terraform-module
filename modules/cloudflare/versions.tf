terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 5.5"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3"
    }
  }
}
