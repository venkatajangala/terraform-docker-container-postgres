# Terraform-managed Postgres Container

This Terraform configuration deploys a PostgreSQL database container using Docker, with persistent data storage via a named Docker volume.

## Features

- **PostgreSQL Version**: Uses `postgres:18.1-alpine` image
- **Persistent Storage**: Data is stored in a Docker named volume `pgdata` mounted at `/var/lib/postgresql/data`
- **Port Mapping**: Exposes PostgreSQL on host port `5432`
- **Environment Variables**: Configurable user, password, and database name
- **Restart Policy**: Container restarts automatically unless stopped manually

## Variables

- `postgres_user`: Database username (default: `pguser`)
- `postgres_password`: Database password (sensitive, default: `change_me`) - **Change this for production!**
- `postgres_db`: Database name (default: `appdb`)

## Outputs

- `connection_string`: PostgreSQL connection string (sensitive) - e.g., `postgresql://pguser:password@localhost:5432/appdb`

## Prerequisites

- Terraform installed
- Docker running and accessible

## Usage

1. **Initialize Terraform**:
   ```bash
   terraform init
   ```

2. **Apply the configuration** (set a secure password):
   ```bash
   terraform apply -var="postgres_password=your_secure_password"
   ```

3. **Access the database**:
   Use the connection string from outputs or connect directly:
   ```bash
   psql postgresql://pguser:your_secure_password@localhost:5432/appdb
   ```

4. **Destroy the resources**:
   ```bash
   terraform destroy
   ```

## Notes

- If host port `5432` is already in use, edit `main.tf` and change the `external` port under `docker_container.postgres`.
- Store real secrets in `terraform.tfvars` or a secret manager; avoid committing plaintext passwords.
- The Docker volume `pgdata` persists data across container restarts/destroys.
