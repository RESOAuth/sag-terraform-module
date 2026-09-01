# The "blocked" gate, and nothing else.
#
# There is deliberately no `aws_ssm_parameter` *resource* anywhere in this
# module: the parameter that holds a real secret's plaintext is written only by
# scripts/sag-secrets.mjs, which is human-run and TTY-gated, precisely so
# `terraform apply` is never capable of inventing SAG_SECRET. What Terraform
# owns is the `aws:ssm:...` pointer in the Lambda's environment, computed in
# main.tf entirely at plan time, present whether or not the parameter behind it
# exists yet.
#
# `with_decryption = false` is the one invariant in this whole design that a
# single flipped boolean would silently defeat: an existence check that
# decrypted would pull the actual plaintext secret into Terraform state as a
# side effect of the read, which is exactly what this module exists to prevent.
# With decryption off, what comes back and is cached in state is SSM's own
# encrypted representation. test/discipline.tftest.hcl asserts this.

data "aws_ssm_parameters_by_path" "secrets" {
  path      = local.secrets_prefix
  recursive = false

  # Never true. See above, and test/discipline.tftest.hcl.
  with_decryption = false
}

locals {
  # SSM returns fully-qualified names; the environment variable name is the
  # last segment.
  present_secret_names = [
    for name in data.aws_ssm_parameters_by_path.secrets.names : element(split("/", name), length(split("/", name)) - 1)
  ]

  missing_secrets = sort(setsubtract(local.secret_names, local.present_secret_names))

  blocked_message = <<-EOT
    This instance is blocked on secrets that do not exist yet.

    SAG treats an `aws:ssm:` pointer it cannot resolve as a hard start-up
    error, so applying with these missing would deploy a function that cannot
    start. Set each of them out-of-band, then plan again:

    ${join("\n", [for name in local.missing_secrets : "      scripts/sag-secrets.mjs set --instance ${coalesce(var.platform_domain, var.identity)} --region ${local.region} --name ${name}"])}

    Missing: ${join(", ", local.missing_secrets)}
    Path:    ${local.secrets_prefix}/
    Key:     ${local.names.secrets_alias}

    On the very first apply of a brand-new instance the key those parameters
    are written under does not exist yet, so set aws.require_secrets = false
    for that one apply and turn it back on straight after.
  EOT
}
