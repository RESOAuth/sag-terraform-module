# The slug is deterministic and fixed-length, for any hostname.
#
# Every AWS resource name is built from this, and two of them - the S3 bucket
# and the IAM role - are capped at 63 and 64 characters, so a slug that grew
# with the hostname would eventually produce a name AWS refuses. That is the
# whole reason the tail is a hash rather than the rest of the hostname.
#
# No provider is ever reached: every case asserts on module outputs computed
# entirely at plan time.

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

# The secrets gate is deliberately on by default and asserted in
# discipline.tftest.hcl; these cases are about naming, and every one of them
# would otherwise stop at "blocked on secrets that do not exist yet".
variables {
  instance = {
    aws = {
      region          = "eu-west-2"
      cdn             = "none"
      require_secrets = false
    }
  }
}

run "short_hostname" {
  command = plan

  variables {
    instance = {
      domain = "id.example.com"
      aws    = { region = "eu-west-2", cdn = "none", require_secrets = false }
    }
  }

  assert {
    condition     = module.sag.slugs["aws"] == "idexamplec-a786eb0d891f1b9793d5"
    error_message = "the slug for id.example.com changed: got ${module.sag.slugs["aws"]}"
  }
}

run "hostname_shorter_than_the_prefix_length" {
  command = plan

  variables {
    instance = {
      name = "sandbox"
      aws = {
        region          = "eu-west-2"
        cdn             = "none"
        require_secrets = false
        # A domainless instance has to state its own issuer: see the
        # precondition in modules/aws/lambda.tf for why Terraform cannot
        # derive it from the Function URL.
        extra_vars = { SAG_ISSUER = "https://example.lambda-url.eu-west-2.on.aws" }
      }
    }
  }

  # `substr` errors rather than truncating when the string is shorter than the
  # requested length, so a 7-character identity is the case that would break a
  # naive expression - and it is a real one: a live account still holds keys
  # from a `name = "sandbox"` instance.
  assert {
    condition     = module.sag.slugs["aws"] == "sandbox-9ed037b84943c4caa3a5"
    error_message = "a resource key shorter than the 10-character prefix must not error or pad: got ${module.sag.slugs["aws"]}"
  }
}

run "very_long_hostname_stays_fixed_length" {
  command = plan

  variables {
    instance = {
      domain = "a-very-long-subdomain-indeed.with-another-long-label.example.com"
      aws    = { region = "eu-west-2", cdn = "none", require_secrets = false }
    }
  }

  # 10 prefix + 1 hyphen + 20 hex = 31, always. `sag-` plus this plus
  # `-clients` is 42 characters, well inside the S3 cap.
  assert {
    condition     = length(module.sag.slugs["aws"]) == 31
    error_message = "the slug must be 31 characters whatever the hostname length: got ${length(module.sag.slugs["aws"])}"
  }
}

run "punctuation_is_stripped_from_the_prefix_but_not_the_hash" {
  command = plan

  variables {
    instance = {
      domain = "aws-eu-west-2.sandbox.resoauth.cloud"
      aws    = { region = "eu-west-2", cdn = "none", require_secrets = false }
    }
  }

  # The exact slug a live deployment's resources are named from. If this
  # assertion ever fails, the module has stopped being able to find them.
  assert {
    condition     = module.sag.slugs["aws"] == "awseuwest2-a617a646ba7747f76489"
    error_message = "the slug for a live instance changed: got ${module.sag.slugs["aws"]}"
  }
}

run "hostnames_that_strip_to_the_same_prefix_stay_distinct" {
  command = plan

  variables {
    instance = {
      domain = "a.bexample.com"
      aws    = { region = "eu-west-2", cdn = "none", require_secrets = false }
    }
  }

  # `a.bexample.com` and `ab.example.com` both strip to `abexamplec`. The hash
  # covers the whole hostname, punctuation included, so they cannot collide.
  assert {
    condition     = module.sag.slugs["aws"] == "abexamplec-400edb618f9fbebd1424"
    error_message = "expected the punctuation to affect the hash: got ${module.sag.slugs["aws"]}"
  }
}

run "the_other_hostname_with_that_prefix" {
  command = plan

  variables {
    instance = {
      domain = "ab.example.com"
      aws    = { region = "eu-west-2", cdn = "none", require_secrets = false }
    }
  }

  assert {
    condition     = module.sag.slugs["aws"] == "abexamplec-d2c36edfd4e978c035c3"
    error_message = "expected a different hash from a.bexample.com: got ${module.sag.slugs["aws"]}"
  }
}

run "case_is_not_significant" {
  command = plan

  variables {
    instance = {
      domain = "ID.Example.COM"
      aws    = { region = "eu-west-2", cdn = "none", require_secrets = false }
    }
  }

  assert {
    condition     = module.sag.slugs["aws"] == "idexamplec-a786eb0d891f1b9793d5"
    error_message = "the hostname must be lower-cased before hashing: got ${module.sag.slugs["aws"]}"
  }
}
