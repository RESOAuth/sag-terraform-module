# The two per-instance KMS keys.
#
# A KMS key is the one thing `apply` creates that holds secret material, and it
# is not an exception to "apply never generates a secret value": nobody chooses
# the value, AWS generates it inside the HSM, and it never comes back out
# through any API, Terraform's included. That makes managing the key resource
# exactly as safe as managing an empty DynamoDB table - see
# docs/aws-secret-references.md, "What ends up where".
#
# The alias is what keeps this keyed off the domain: the key id is random, the
# alias is derived from the slug, so SIGNING_KMS_KEY_ID can name the alias and
# never has to be told a key id.

resource "aws_kms_key" "signing" {
  # checkov:skip=CKV_AWS_7:KMS cannot rotate an asymmetric key's material - the public half is published in the JWKS and relying parties cache it. Rotation here is a new key with a new kid, which is an operator decision, not a schedule.
  # checkov:skip=CKV2_AWS_64:The default key policy - delegate to IAM for this account - is deliberate. What may use this key is decided by aws_iam_role_policy.exec, which names the key ARN and nothing else, rather than by a second policy language saying the same thing in a different place.
  description              = "SAG id_token signing key (${local.names.signing_alias})"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  tags                     = local.tags
}

resource "aws_kms_alias" "signing" {
  name          = local.names.signing_alias
  target_key_id = aws_kms_key.signing.key_id
}

resource "aws_kms_key" "secrets" {
  # checkov:skip=CKV2_AWS_64:As above - access is granted by aws_iam_role_policy.exec against this key's ARN.
  description = "SAG secret sealing key (${local.names.secrets_alias})"
  key_usage   = "ENCRYPT_DECRYPT"

  # Free, and safe for this key specifically: KMS keeps every previous version's
  # material for decryption, so a SecureString parameter written last year still
  # reads back after a rotation. The signing key cannot do this; a symmetric
  # sealing key can, so it should.
  enable_key_rotation = true
  # SecureString parameters under this instance's secrets path are encrypted
  # with this key by scripts/sag-secrets.mjs, and decrypted for the
  # execution role by SSM at start-up. Terraform holds neither the plaintext
  # nor the ciphertext of anything it protects.
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  tags                     = local.tags
}

resource "aws_kms_alias" "secrets" {
  name          = local.names.secrets_alias
  target_key_id = aws_kms_key.secrets.key_id
}
