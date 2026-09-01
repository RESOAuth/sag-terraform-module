# The relying-party store, when this block keeps one.

resource "cloudflare_workers_kv_namespace" "clients" {
  count = local.use_clients ? 1 : 0

  account_id = var.block.account_id
  title      = local.names.clients_namespace
}
