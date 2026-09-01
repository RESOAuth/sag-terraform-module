# The single-use code and send-limit store.
#
# TTL on `expires_at` is not optional in practice: without it every single-use
# code SAG writes stays in the table for good.

resource "aws_dynamodb_table" "state" {
  count = var.block.state_store == "dynamo-db" ? 1 : 0

  name         = local.names.state_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "jti"

  attribute {
    name = "jti"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    # Everything in this table is short-lived by construction and re-derivable
    # from nothing: a point-in-time restore of expired single-use codes has no
    # value, and paying continuous-backup rates for it has a cost.
    enabled = false
  }

  server_side_encryption {
    # AWS-owned key. Nothing in this table is secret material - a `jti` and an
    # expiry - so a customer-managed key would add cost and a rotation
    # obligation without protecting anything.
    enabled = false
  }

  tags = local.tags
}
