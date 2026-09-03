output "platform_domain" {
  description = "The hostname this block answers on."
  value       = var.platform_domain
}

output "slug" {
  description = "The instance slug every resource name in this block derives from."
  value       = var.slug
}

output "issuer" {
  description = "SAG_ISSUER as deployed."
  value       = var.common.issuer
}

output "jwks_url" {
  description = "This block's JWKS URL, which a sibling block lists as a peer."
  value       = "https://${var.platform_domain}/.well-known/jwks.json"
}

output "worker_name" {
  value = cloudflare_workers_script.main.script_name
}

output "hsm_worker_name" {
  value = cloudflare_workers_script.hsm.script_name
}

output "clients_namespace_id" {
  value = local.use_clients ? cloudflare_workers_kv_namespace.clients[0].id : null
}

output "secret_names" {
  description = <<-EOT
    Every secret this block implies, per Worker. Both are set with
    `wrangler secret put` by scripts/sag-secrets.mjs; nothing here can read
    one back, which is the point.
  EOT
  value = {
    (cloudflare_workers_script.main.script_name) = local.worker_secret_names
    (cloudflare_workers_script.hsm.script_name)  = local.hsm_secret_names
  }
}

output "release" {
  description = "What version resolved to, so a plan or apply log records which code went out."
  value = {
    requested = var.common.sag_version
    tag       = data.external.release.result.tag
    commit    = data.external.release.result.commit
    source    = data.external.release.result.source
  }
}

output "resources" {
  description = <<-EOT
    What this block manages, entirely known at plan time - the same reviewable
    summary modules/aws exposes, and what test/render.tftest.hcl asserts
    against. The bindings are part of it because a missing binding is not a
    start-up error: SAG reaches for `HSM` on the first signature and for
    `SEND_EMAIL` on the first OTP, so a block missing one looks healthy right
    up until somebody uses it.
  EOT
  value = {
    worker              = local.names.worker
    hsm_worker          = local.names.hsm_worker
    clients_namespace   = local.use_clients ? local.names.clients_namespace : null
    state_class         = local.use_state ? local.names.state_class : null
    creates_state_class = local.create_state_class
    custom_domain       = var.platform_domain
    bindings            = { for b in local.worker_bindings : b.name => b.type if b.type != "plain_text" }
    invocation_logs     = var.block.invocation_logs
  }
}

output "environment" {
  description = "The main Worker's plain-text variable bindings as rendered. Secrets are absent by construction: they are separate, write-only bindings set by wrangler."
  value       = local.environment
}
