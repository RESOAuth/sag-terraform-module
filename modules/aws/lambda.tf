# The function, its URL, and its log group.
#
# Terraform owns the whole `environment.variables` map on every apply, with no
# `lifecycle.ignore_changes` anywhere - the merge-vs-replace hazard that would
# otherwise force one does not arise, because every value in this map is either
# non-secret configuration or an `aws:ssm:` pointer, and a pointer was never
# secret to begin with.

resource "aws_cloudwatch_log_group" "sag" {
  # checkov:skip=CKV_AWS_158:A customer-managed key on the log group would mean granting the role kms: on a third key and paying for it, to protect logs that carry no secret - SAG logs no secret value, and the environment it starts from holds pointers rather than values.
  # Created here rather than left to Lambda's own first-invocation creation, so
  # retention is set from the start: a group Lambda makes for itself keeps logs
  # forever and bills for them forever.
  name              = local.names.log_group
  retention_in_days = var.block.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "sag" {
  # checkov:skip=CKV_AWS_173:The environment is encrypted at rest with the AWS-managed Lambda key, and a customer-managed one would protect nothing extra: every session- or encryption-relevant value in this map is an `aws:ssm:` pointer naming a path, not a secret. That is the whole design - see docs/aws-secret-references.md.
  # checkov:skip=CKV_AWS_117:A VPC would cut off outbound access to the upstream IdPs SAG federates to, and restoring it means a NAT gateway for a function whose entire job is talking to the public internet.
  # checkov:skip=CKV_AWS_116:A dead-letter queue applies to asynchronous invocation. SAG is only ever invoked synchronously over its Function URL, so there is nothing for a DLQ to catch.
  # checkov:skip=CKV_AWS_115:A reserved concurrency limit on a public sign-in endpoint converts a traffic spike into a sign-in outage. Rate limiting belongs at the edge, which is what aws.waf.create is for.
  # checkov:skip=CKV_AWS_50:X-Ray traces an OIDC flow's requests, including query strings carrying authorization codes and state. Not on by default for an auth endpoint.
  # checkov:skip=CKV_AWS_272:Code signing needs a signing profile and a publisher identity this module has no way to establish. What it does instead is name the resolved tag and commit in the plan, and hash the package with source_code_hash.
  function_name = local.names.function
  role          = aws_iam_role.exec.arn
  handler       = local.handler
  runtime       = var.block.runtime
  architectures = [var.block.architecture]
  memory_size   = var.block.memory_mb
  timeout       = var.block.timeout_seconds

  filename         = data.archive_file.package.output_path
  source_code_hash = data.archive_file.package.output_base64sha256

  environment {
    variables = local.environment
  }

  tags = local.tags

  depends_on = [
    aws_cloudwatch_log_group.sag,
    aws_iam_role_policy.exec,
  ]

  lifecycle {
    precondition {
      condition     = !var.block.require_secrets || length(local.missing_secrets) == 0
      error_message = local.blocked_message
    }

    # A domainless instance would have to take its issuer from the URL its
    # platform generates, and that needs two passes - deploy the function, then
    # update its environment. Terraform cannot do that: the environment would
    # depend on the Function URL, which depends on the function, which is a
    # cycle rather than an ordering. So the issuer has to be stated, and it is
    # better to say that than to deploy a SAG that infers one from a request's
    # Host header.
    precondition {
      condition     = var.common.issuer != null || contains(keys(local.environment), "SAG_ISSUER")
      error_message = <<-EOT
        This instance has a "name" but no "domain", so nothing here knows what
        issuer it should claim, and SAG must never infer one from a request's
        Host header.

        Apply once to create the function, then set SAG_ISSUER in the block's
        extra_vars to the Function URL it was given and apply again:

          "extra_vars": { "SAG_ISSUER": "https://<url-id>.lambda-url.${local.region}.on.aws" }

        Terraform cannot fill this in itself: the environment would have to
        depend on the Function URL, which depends on the function whose
        environment it is.
      EOT
    }
  }
}

resource "aws_lambda_function_url" "sag" {
  # checkov:skip=CKV_AWS_258:Deliberate. A public OIDC endpoint has to be reachable without AWS credentials; IAM auth would mean only SigV4 callers could sign in. CloudFront fronts it and attaches a shared origin header, and the TLS hostname a browser reaches is the distribution's, not this one.
  function_name = aws_lambda_function.sag.function_name

  # Deliberately public, precisely so any CDN can front it: CloudFront cannot
  # sign a request to a Function URL without Origin Access Control on a
  # different origin type, and SAG is a public OIDC endpoint regardless. The
  # shared origin header narrows who *should* reach it, not who can.
  authorization_type = "NONE"
  invoke_mode        = "BUFFERED"
}

# A Function URL with AuthType NONE still needs a resource policy: AWS does not
# add one when the URL is created through the API, and without it every request
# is 403 with nothing in the function's own logs to explain it.
#
# Since October 2025 Lambda requires *both* of these for a public Function URL,
# which is why the second one exists and is not redundant. The InvokeFunction
# grant must carry the InvokedViaFunctionUrl condition: without it, the same
# statement would let any AWS principal invoke the function through the Invoke
# API, bypassing the HTTP boundary - and therefore the CDN - entirely.
resource "aws_lambda_permission" "function_url" {
  # checkov:skip=CKV_AWS_301:As above - a public sign-in endpoint is public on purpose.
  statement_id           = "sag-public-function-url"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.sag.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "function_url_invoke" {
  # checkov:skip=CKV_AWS_301:As above, and narrowed further by invoked_via_function_url below, which is what stops this being a general invoke grant.
  statement_id  = "sag-public-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sag.function_name
  principal     = "*"

  # The condition is what keeps this statement narrow: without it, the same
  # statement would let any AWS principal invoke the function through the
  # Invoke API, bypassing the HTTP boundary - and therefore the CDN - entirely.
  # AWS rejects FunctionUrlAuthType on lambda:InvokeFunction, so this is the
  # only condition available here, and it is the one AWS documents.
  invoked_via_function_url = true
}
