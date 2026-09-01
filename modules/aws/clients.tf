# The relying-party store.
#
# Relying-party records are not public, and a bucket that is briefly public by
# default is a bucket that can be found while it is - so the public access
# block is part of creating it, not a follow-up.

resource "aws_s3_bucket" "clients" {
  # checkov:skip=CKV_AWS_145:SSE-S3 rather than a customer-managed key, for the reason given on the encryption configuration below: a client record is public metadata, and a second key would widen the execution role for nothing.
  # checkov:skip=CKV_AWS_18:Access logging needs a second bucket and bills per request, to record reads of public relying-party metadata by the one role allowed to read it.
  # checkov:skip=CKV_AWS_144:Cross-region replication is for data that would be painful to lose. These objects are relying-party registrations, versioned below, and recreated by re-registering.
  # checkov:skip=CKV2_AWS_61:A lifecycle rule would expire relying-party registrations, which are meant to outlive everything else in this instance.
  # checkov:skip=CKV2_AWS_62:Nothing consumes an event from this bucket. SAG reads a client record on demand; there is no pipeline to notify.
  count = var.block.clients_store == "s3" ? 1 : 0

  bucket = local.names.clients_bucket
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "clients" {
  count = var.block.clients_store == "s3" ? 1 : 0

  bucket = aws_s3_bucket.clients[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "clients" {
  count = var.block.clients_store == "s3" ? 1 : 0

  bucket = aws_s3_bucket.clients[0].id

  versioning_configuration {
    # A relying-party registration deleted or overwritten by mistake is
    # otherwise unrecoverable, and the objects are tiny.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "clients" {
  count = var.block.clients_store == "s3" ? 1 : 0

  bucket = aws_s3_bucket.clients[0].id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 rather than the instance's own KMS key: a client record is public
      # metadata (redirect URIs, a client id), and giving the execution role
      # kms:Decrypt on a second key widens the role for no gain.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}
