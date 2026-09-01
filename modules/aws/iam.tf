# The execution role, scoped to exactly this instance's own resources.
#
# Key ARNs rather than aliases in every resource element, because an alias in a
# resource element does not constrain what it points at.

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "LambdaAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "exec" {
  name               = local.names.role
  description        = "SAG execution role, managed by the SAG Terraform module"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "exec" {
  statement {
    sid       = "SignIdTokens"
    effect    = "Allow"
    actions   = ["kms:Sign", "kms:GetPublicKey"]
    resources = [aws_kms_key.signing.arn]
  }

  # Needed at runtime, transparently: SSM decrypts a SecureString parameter on
  # the role's behalf, so the role - not this module - is what has to be able to
  # use the key.
  statement {
    sid       = "DecryptOwnSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.secrets.arn]
  }

  # Scoped to exactly this instance's secrets path, so a compromised function
  # cannot read a sibling instance's secrets even in the same account.
  statement {
    sid       = "ReadOwnSecrets"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.secrets_prefix}/*"]
  }

  statement {
    sid       = "WriteOwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.names.log_group}:*"]
  }

  dynamic "statement" {
    for_each = var.block.state_store == "dynamo-db" ? [1] : []

    content {
      sid       = "SingleUseCodesAndSendLimits"
      effect    = "Allow"
      actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
      resources = ["arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table/${local.names.state_table}"]
    }
  }

  dynamic "statement" {
    for_each = var.block.clients_store == "s3" ? [1] : []

    content {
      sid       = "ReadRelyingParties"
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["arn:${local.partition}:s3:::${local.names.clients_bucket}/clients/*"]
    }
  }

  dynamic "statement" {
    for_each = try(local.email.provider, null) == "ses" ? [1] : []

    content {
      sid     = "SendSignInCodes"
      effect  = "Allow"
      actions = ["ses:SendEmail"]
      # SES has no per-identity resource ARN for SendEmail that covers both a
      # domain and an address identity, so the constraint is the condition
      # below: only ever from the address this instance is configured to send as.
      resources = ["*"]

      dynamic "condition" {
        for_each = local.email_from_address == null ? [] : [local.email_from_address]

        content {
          test     = "StringEquals"
          variable = "ses:FromAddress"
          values   = [condition.value]
        }
      }
    }
  }
}

resource "aws_iam_role_policy" "exec" {
  name   = local.names.role_policy
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec.json
}
