resource "null_resource" "vault_init" {
  count = var.vault_enabled ? 1 : 0
  depends_on = [docker_container.vault]

  provisioner "local-exec" {
    command = "bash ${path.module}/vault-bootstrap.sh ${var.vault_port} pg-role ${var.postgres_user} ${local.postgres_password} ${local.replication_password}"
    environment = {
      VAULT_ADDR = "http://localhost:${var.vault_port}"
      VAULT_TOKEN = var.vault_root_token
    }
  }

  triggers = {
    vault_enabled   = tostring(var.vault_enabled)
    vault_root_token = var.vault_root_token
  }
}

resource "null_resource" "vault_seed" {
  count = var.vault_enabled ? 1 : 0
  depends_on = [null_resource.vault_init]

  provisioner "local-exec" {
    command = "echo 'Vault seed completed'"
  }

  triggers = {
    seed = "${var.postgres_user}:${var.password_length}:${var.generate_new_passwords}"
  }
}
