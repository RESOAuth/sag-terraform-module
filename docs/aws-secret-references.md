# How a secret reaches the function on AWS

The RFC this file used to hold has been decided and shipped. SAG's own
[`docs/adr/0018-sealed-environment-variables.md`][adr] is now the authority on
the mechanism; this describes only what this module does with it, which is a
deliberately narrow slice of what SAG supports.

[adr]: https://github.com/RESOAuth/smart-access-gateway/blob/main/docs/adr/0018-sealed-environment-variables.md

## The shape

SAG resolves three reference forms, detected by the value's prefix rather than
by the variable's name:

| Form | Resolved by |
| --- | --- |
| `aws:kms:<ciphertext>` | `kms:Decrypt` |
| `aws:secretsmanager:<secret id>` | Secrets Manager, at start-up |
| `aws:ssm:<parameter name>` | SSM Parameter Store, at start-up |

**This module produces the third, and only the third.** It is the one form
where the environment variable's value is not sensitive at all - not even
ciphertext. `aws:ssm:/sag/awseuwest2-a617a646ba7747f76489/secrets/SAG_SECRET`
reveals a path, and anyone who can read it could have derived that path from
the domain anyway.

Detection by prefix rather than by name matters: no fixed list of "these names
are always references" has to exist, or stay in sync with every new
`UPSTREAM_*_CLIENT_SECRET` an instance introduces.

## The path a secret takes

1. `terraform apply` creates a symmetric KMS key per instance,
   `alias/sag-<slug>-secrets`, and grants the execution role `kms:Decrypt` on
   it plus `ssm:GetParameter` on exactly
   `arn:aws:ssm:<region>:<account>:parameter/sag/<slug>/secrets/*`.
2. `terraform apply` writes `<NAME> = "aws:ssm:/sag/<slug>/secrets/<NAME>"`
   into the Lambda's environment - a plain string built in `locals`, present
   whether or not the parameter behind it exists yet.
3. A **person** runs `scripts/sag-secrets.mjs set`, which writes the real
   value to that path as a `SecureString` under that key. It refuses to run
   without a TTY, and `terraform apply` has no way to reach it.
4. SAG resolves every reference at start-up, before it parses its config. A
   value it cannot fetch or decrypt is a hard start-up error - never a silent
   fallback to an empty string.

Terraform never creates the `aws_ssm_parameter` resource that holds the value.
`scripts/check-discipline.mjs` fails if one ever appears.

## What ends up where

| | Plaintext | Ciphertext |
| --- | --- | --- |
| SSM Parameter Store | no - encrypted at rest under the instance key | yes |
| The running Lambda's memory | yes, once fetched | - |
| The Lambda's environment | no - a path | no |
| Terraform state | **no** | only what the presence check reads back |

The last cell is the one to be careful about. The `require_secrets` gate reads
the instance's secrets path to report which secrets are still missing, and that
read sets `with_decryption = false`, without exception: decrypting it would pull
the plaintext into state as a side effect of checking whether it exists. What
state holds instead is SSM's own encrypted representation - an `AQICAHg...`
blob. Both `test/discipline.tftest.hcl` and `scripts/check-discipline.mjs`
assert this, because it is the one invariant in the whole design that a single
flipped boolean would silently defeat.

## Rotation

`SAG_SECRET_PREVIOUS` is a second reference, set the same way. It is opt-in via
`session.rotating`, and the ordering matters: SAG treats a reference it cannot
resolve as a hard start-up error, so write the parameter first and only then
turn `rotating` on. Setting it the other way round takes the instance down.

Nothing else needs to run for a rotation. The Lambda's environment did not
change - only the value behind a path it already carried.
