resource "null_resource" "vault_init" {
  count      = var.vault_enabled ? 1 : 0
  depends_on = [docker_container.vault]

  provisioner "local-exec" {
    command = "bash ${path.module}/vault-bootstrap.sh ${var.vault_port} pg-role ${var.postgres_user} ${local.postgres_password} ${local.replication_password}"
    environment = {
      # VAULT_ADDR is set here for the host-side curl calls in vault-bootstrap.sh.
      # VAULT_TOKEN is NOT pre-set — the script initialises Vault and obtains the
      # root token dynamically from vault operator init on first run.
      VAULT_ADDR = "http://localhost:${var.vault_port}"
    }
  }

  triggers = {
    vault_enabled = tostring(var.vault_enabled)
    # Changing passwords or the pg user forces a re-seed of KV secrets
    seed = "${var.postgres_user}:${var.password_length}:${var.generate_new_passwords}"
    # Re-run whenever the vault-data volume is recreated (e.g. after terraform destroy + apply)
    vault_volume_id = docker_volume.vault_data[0].id
  }
}

resource "null_resource" "vault_seed" {
  count      = var.vault_enabled ? 1 : 0
  depends_on = [null_resource.vault_init]

  provisioner "local-exec" {
    command = "echo 'Vault seed completed'"
  }

  triggers = {
    seed = "${var.postgres_user}:${var.password_length}:${var.generate_new_passwords}"
  }
}
