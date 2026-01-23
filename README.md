# Terraform-managed Postgres with DBHub (MCP) Integration

This Terraform configuration deploys PostgreSQL and DBHub (Bytebase) containers using Docker with a custom bridge network for inter-container communication. DBHub provides a web interface for managing your PostgreSQL databases.

## Features

- **PostgreSQL Version**: Uses `postgres:18.1-alpine` image
- **Persistent Storage**: Data is stored in a Docker named volume `pgdata` mounted at `/var/lib/postgresql/data`
- **Custom Bridge Network**: Both containers communicate securely via `mcp-network`
- **DBHub Web Interface**: Bytebase web UI for database management and SQL execution
- **Port Mappings**:
  - PostgreSQL: `5432` (internal and external)
  - DBHub: `9090` (external, internally `8080`)
- **Environment Variables**: Configurable credentials and ports
- **Restart Policy**: Containers restart automatically unless stopped manually

## Architecture

```
┌─────────────────────┐         ┌────────────────────┐
│   DBHub Container   │         │  Postgres Container│
│  (port 9090)        │◄────────┤  (port 5432)       │
│  bytebase/bytebase  │         │  postgres:18.1     │
└─────────────────────┘         └────────────────────┘
         │                              │
         └──────────────────────────────┘
            Connected via mcp-network
```

## Variables

- `postgres_user`: Database username (default: `pgadmin`)
- `postgres_password`: Database password (sensitive, default: `pgAdmin1`) - **Change this for production!**
- `postgres_db`: Database name (default: `postgres`)
- `dbhub_port`: DBHub web interface port (default: `9090`)

## Outputs

- `connection_string`: PostgreSQL connection string from host machine (sensitive)
- `postgres_container_name`: Name of PostgreSQL container
- `dbhub_container_name`: Name of DBHub container
- `dbhub_url`: DBHub web interface URL
- `mcp_network`: Custom bridge network name
- `postgres_dsn_internal`: PostgreSQL DSN for internal container communication

## Prerequisites

- Terraform installed
- Docker running and accessible

## Usage

1. **Initialize Terraform**:
   ```bash
   terraform init
   ```

2. **Apply the configuration**:
   ```bash
   terraform apply -auto-approve
   ```

   Or with custom variables:
   ```bash
   terraform apply -var="postgres_password=your_secure_password" -var="dbhub_port=9090"
   ```

3. **Access the services**:
   - **DBHub Web UI**: Open `http://localhost:9090` in your browser
   - **PostgreSQL Direct Connection**:
     ```bash
     psql postgresql://pgadmin:pgAdmin1@localhost:5432/postgres
     ```
   - **Connection String** (from outputs):
     ```bash
     terraform output -raw connection_string
     ```

4. **View container status**:
   ```bash
   docker ps | grep -E "dbhub|my-postgres"
   ```

5. **Destroy the resources**:
   ```bash
   terraform destroy -auto-approve
   ```

## DBHub Features

- **Web-based Database Management**: Query, edit, and manage databases through the web interface
- **Multi-database Support**: Connect to multiple databases
- **SQL Editor**: Execute and save SQL queries
- **Schema Management**: View and manage database schemas
- **Version Control Integration**: Track schema changes

## Network Details

- **Network Name**: `mcp-network`
- **Driver**: Bridge
- **Container-to-Container Communication**: DBHub connects to PostgreSQL using the container name `my-postgres:5432` instead of `localhost:5432`

## Notes

- If host port `5432` or `9090` is already in use, you can pass custom port variables or modify the defaults in `variables.tf`
- Store real secrets in `terraform.tfvars` or a secret manager; avoid committing plaintext passwords
- The Docker volume `pgdata` persists data across container restarts/destroys
- The custom bridge network ensures secure and isolated communication between containers
- PostgreSQL uses `sslmode=disable` for development; enable SSL in production

## Troubleshooting

**DBHub shows "Connection refused"**:
- Ensure PostgreSQL container is running: `docker ps | grep my-postgres`
- Check PostgreSQL logs: `docker logs my-postgres`

**Port already in use**:
- Change the port variable: `terraform apply -var="dbhub_port=8081"`

**Cannot connect to DBHub**:
- Verify the container is running: `docker ps | grep dbhub`
- Check DBHub logs: `docker logs dbhub`
- Verify network connectivity: `docker network inspect mcp-network`
