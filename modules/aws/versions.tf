terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 6.0"
      configuration_aliases = [aws.us_east_1]
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
