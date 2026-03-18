# Terraform Commands Reference Guide

Complete reference for all Terraform commands used in PostgreSQL HA Cluster deployment.

## Table of Contents
- [Basic Commands](#basic-commands)
- [Planning & Deployment](#planning--deployment)
- [State Management](#state-management)
- [Variables & Configuration](#variables--configuration)
- [Output Management](#output-management)
- [Troubleshooting](#troubleshooting)
- [Advanced Operations](#advanced-operations)

---

## Basic Commands

### Initialize Terraform Working Directory

```bash
# Initialize (required before any other commands)
terraform init

# Upgrade provider versions
terraform init -upgrade

# Specify backend config
terraform init -backend-config="path=/var/terraform"
```

**Purpose:** Sets up the working directory, downloads provider plugins, initializes state files.

### Validate Configuration

```bash
# Validate Terraform syntax
terraform validate

# Validate specific file
terraform validate main-ha.tf

# Validate with quiet output
terraform validate -quiet 2>&1 && echo "✓ Valid" || echo "✗ Invalid"
```

**Purpose:** Checks for syntax errors and resource dependencies before planning.

### Format Code

```bash
# Format all Terraform files in current directory
terraform fmt

# Format recursive (subdirectories)
terraform fmt -recursive .

# Check formatting without applying (dry-run)
terraform fmt -check -recursive .

# Format with verbose output
terraform fmt -recursive . -write=true
```

**Purpose:** Ensures consistent code style and readability.

---

## Planning & Deployment

### Generate Execution Plan

```bash
# Standard plan (prints to stdout)
terraform plan

# Save plan to file (binary format, for reproducible applies)
terraform plan -out=tfplan

# Plan specific resource
terraform plan -target='docker_container.pg_node["1"]'

# Plan destruction
terraform plan -destroy

# Plan with specific variables
terraform plan -var="pg_node_memory_mb=8192"

# Plan with variable file
terraform plan -var-file="terraform.tfvars"

# Plan with refreshed state
terraform plan -refresh=true

# Plan with detailed output
terraform plan -json > plan.json  # Machine-readable format
```

**Usage:** Always run before `apply` to review what will change.

### View Detailed Plan

```bash
# Display saved plan file (human-readable)
terraform show tfplan | head -100

# Display saved plan in JSON
terraform show -json tfplan | jq .

# Display only resource changes
terraform show tfplan | grep "# "

# Get count of planned changes
terraform plan 2>&1 | grep "Plan:"
```

### Apply Changes

```bash
# Apply with auto-approval (no confirmation prompt)
terraform apply -auto-approve

# Apply specific plan file
terraform apply tfplan

# Apply specific resource
terraform apply -target='docker_container.pg_node["1"]' -auto-approve

# Apply with specific variables
terraform apply -var="postgres_user=pgadmin" -var="pg_node_memory_mb=8192"

# Apply with variable file
terraform apply -var-file="terraform.tfvars" -auto-approve

# Apply with auto-approval and parallelism
terraform apply -auto-approve -parallelism=10

# Apply with detailed logging
TF_LOG=DEBUG terraform apply -auto-approve 2>&1 | tee apply.log
```

**Warning:** `apply` makes actual changes to infrastructure.

### Destroy Infrastructure

```bash
# Show what will be destroyed (plan first)
terraform plan -destroy

# Destroy all resources
terraform destroy -auto-approve

# Destroy with confirmation prompt
terraform destroy  # Prompts: yes/no

# Destroy specific resource
terraform destroy -target='docker_container.pgbouncer' -auto-approve

# Destroy specific resources (multiple)
terraform destroy \
  -target='docker_container.pgbouncer' \
  -target='docker_container.infisical' \
  -auto-approve

# Destroy specific module/count index
terraform destroy -target='docker_container.pg_node["1"]' -auto-approve

# Destroy with reduced parallelism
terraform destroy -auto-approve -parallelism=2  # Sequential destruction
```

**Warning:** `destroy` deletes all managed resources. Data loss is permanent.

---

## State Management

### Inspect State

```bash
# List all resources in state
terraform state list

# List specific resource type
terraform state list | grep docker_container

# Show specific resource details
terraform state show 'docker_container.pg_node["1"]'

# Show state in JSON
terraform state list -json

# Count resources
terraform state list | wc -l
```

### Backup & Restore State

```bash
# Backup current state
cp terraform.tfstate terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)

# View state file (JSON)
cat terraform.tfstate | jq . | head -50

# Restore from backup
cp terraform.tfstate.backup.20260318_194416 terraform.tfstate
terraform refresh
```

### Refresh State

```bash
# Sync state with actual infrastructure
terraform refresh

# Refresh specific resource
terraform refresh -target='docker_container.pg_node["1"]'

# Refresh without refreshing remote
terraform refresh -lock=false
```

### Import Resources

```bash
# Import existing Docker container into Terraform state
terraform import 'docker_container.pg_node["1"]' <container_id>

# Get container ID
docker ps --filter "name=pg-node-1" --format "{{.ID}}"

# Import example:
terraform import 'docker_container.pg_node["1"]' a1b2c3d4e5f6

# Verify import
terraform state show 'docker_container.pg_node["1"]'
```

### Remove from State (Without Destroying)

```bash
# Remove resource from state (container still runs)
terraform state rm 'docker_container.pg_node["1"]'

# Remove multiple
terraform state rm 'docker_container.pg_node["1"]' 'docker_container.pg_node["2"]'

# Note: Container continues running, but Terraform no longer manages it
```

### Replace Resource

```bash
# Force destroy and recreate
terraform apply -replace='docker_container.pg_node["1"]' -auto-approve

# Or via refresh
terraform refresh
terraform apply -target='docker_container.pg_node["1"]' -auto-approve
```

---

## Variables & Configuration

### Use Variables via Command Line

```bash
# Single variable
terraform apply -var="postgres_user=newuser" -auto-approve

# Multiple variables
terraform apply \
  -var="postgres_user=newuser" \
  -var="postgres_password=NewSecurePass123456" \
  -var="pg_node_memory_mb=8192" \
  -auto-approve

# Variable with complex value (JSON)
terraform apply -var='tags={"Environment":"prod","Team":"dba"}' -auto-approve
```

### Use Variables via File

```bash
# Create terraform.tfvars
cat > terraform.tfvars <<EOF
postgres_user = "pgadmin"
postgres_password = "SecurePass123456"
postgres_db = "postgres"
pg_node_memory_mb = 4096
pgbouncer_replicas = 2
pgbouncer_max_client_conn = 1000
infisical_enabled = true
EOF

# Apply using tfvars file
terraform apply -var-file="terraform.tfvars" -auto-approve

# Use multiple tfvars files
terraform apply \
  -var-file="base.tfvars" \
  -var-file="prod.tfvars" \
  -auto-approve
```

### Use Environment Variables

```bash
# Set via environment variables (TF_VAR_* prefix)
export TF_VAR_postgres_user="pgadmin"
export TF_VAR_postgres_password="SecurePass123456"
export TF_VAR_pg_node_memory_mb="8192"
export TF_VAR_pgbouncer_replicas="3"

# Now terraform uses these values
terraform apply -auto-approve

# Check set variables
env | grep TF_VAR_
```

### Validate Variables

```bash
# Terraform validates on apply, but can check earlier:
terraform validate

# Or use a plan to catch errors
terraform plan -var-file="test.tfvars" 2>&1 | grep -i error
```

---

## Output Management

### View Outputs

```bash
# Display all outputs
terraform output

# Display specific output
terraform output cluster_status

# Display as raw value (no quotes)
terraform output -raw cluster_status

# Display as JSON
terraform output -json

# Get sensitive value
terraform output generated_passwords

# Get specific sensitive value
terraform output -json generated_passwords | jq '.db_admin_password'
```

### Query Outputs

```bash
# Get database endpoint
terraform output -raw pg_primary_endpoint

# Get connection info
terraform output connection_info | jq .

# Get PostgreSQL username
terraform output connection_info | jq -r '.postgres_user'

# Get all port mappings
terraform output pgbouncer_external_ports

# Get cluster nodes
terraform output pg_nodes

# Extract value for use in script
POSTGRES_USER=$(terraform output -json connection_info | jq -r '.postgres_user')
POSTGRES_DB=$(terraform output -json connection_info | jq -r '.postgres_db')

echo "Connecting to: $POSTGRES_USER@$POSTGRES_DB"
```

---

## Troubleshooting

### Debugging

```bash
# Enable debug logging
TF_LOG=DEBUG terraform plan

# Save debug logs to file
TF_LOG=DEBUG terraform plan > debug.log 2>&1
TF_LOG_PATH=./terraform.log terraform apply -auto-approve

# Trace level (very verbose)
TF_LOG=TRACE terraform plan 2>&1 | head -100

# Disable logging
TF_LOG=off terraform plan
```

### Validation & Syntax Check

```bash
# Check syntax
terraform validate

# Format check (without fixing)
terraform fmt -check -recursive .

# List providers required
terraform providers

# Lock provider version
terraform providers lock -platform=linux_amd64 -platform=darwin_amd64
```

### Dependency Analysis

```bash
# Show resource graph
terraform graph

# Generate visual graph (requires Graphviz)
terraform graph | dot -Tsvg > graph.svg

# Show resource dependencies
terraform state show 'docker_container.pg_node["1"]' | grep "depends_on"

# Check specific dependencies
terraform show -json | jq '.values.root_module.resources[] | {address, type, depends_on}'
```

### Lock Management

```bash
# View lock file (.terraform.lock.hcl)
cat .terraform.lock.hcl | head -20

# Update provider versions (respecting lock file)
terraform init -upgrade

# Migrate lock file to new platform
terraform providers lock -platform=linux_amd64

# Force unlock (use carefully)
terraform force-unlock <lock-id>
```

### State Corruption Recovery

```bash
# Backup state
cp terraform.tfstate terraform.tfstate.corrupted

# Restore from backup
cp terraform.tfstate.backup terraform.tfstate

# Refresh state from actual infrastructure
terraform refresh

# Validate state syntax
jq . terraform.tfstate > /dev/null && echo "✓ Valid JSON"

# Check for conflicts
grep -r "<<<<<<" .  # Look for merge conflicts
```

---

## Advanced Operations

### Workspace Management

```bash
# List workspaces
terraform workspace list

# Create workspace (for multiple environments)
terraform workspace new prod
terraform workspace new staging
terraform workspace new dev

# Switch workspace
terraform workspace select prod

# Show current workspace
terraform workspace show

# Delete workspace
terraform workspace delete dev

# Apply to specific workspace
terraform workspace select prod && terraform apply -auto-approve
```

### Module Operations

```bash
# Validate modules
terraform validate

# Get modules (download dependencies)
terraform get

# Get modules with upgrade
terraform get -update

# Check module outputs
terraform output -module=<module_name>
```

### Import Operations

```bash
# Import Docker network
terraform import docker_network.pg_ha_network pg-ha-network

# Import Docker volume
terraform import docker_volume.etcd_data etcd-data

# Import existing container
docker_id=$(docker ps --filter "name=pg-node-1" -q)
terraform import 'docker_container.pg_node["1"]' "$docker_id"

# Verify import succeeded
terraform plan  # Should show no changes if properly imported
```

### Performance Optimization

```bash
# Increase parallelism (faster operations)
terraform apply -auto-approve -parallelism=20

# Decrease parallelism (for resource-constrained systems)
terraform apply -auto-approve -parallelism=2

# Operations with timing
time terraform apply -auto-approve

# Compress state (removes whitespace)
terraform fmt
```

### Migration & Refactoring

```bash
# Move resource to new address
terraform state mv 'docker_container.pg_node_1' 'docker_container.pg_node["1"]'

# Rename resource in configuration and state
terraform state mv -state-out=new.tfstate 'docker_network.old_network' 'docker_network.new_network'

# Extract module (refactor)
# Move code to modules/ and update references
terraform validate  # Verify after refactoring
```

### CI/CD Integration

```bash
# Non-interactive apply (for CI/CD)
terraform apply -auto-approve \
  -input=false \
  -lock=true \
  -lock-timeout=0s

# Generate plan for review (in CI step 1)
terraform plan -out=tfplan -input=false

# Apply in CI step 2 (after approval)
terraform apply -input=false tfplan

# Get outputs for next steps (in CI step 3)
terraform output -json > outputs.json

# Use output in subsequent CI steps
DATABASE_HOST=$(jq -r '.cluster_info.host' outputs.json)
```

---

## Common Workflows

### Deployment Workflow

```bash
# 1. Validate configuration
terraform validate

# 2. Create plan
terraform plan -var-file="prod.tfvars" -out=tfplan

# 3. Review plan
terraform show tfplan | less

# 4. Apply plan
terraform apply tfplan

# 5. Verify outputs
terraform output

# 6. Backup state
cp terraform.tfstate terraform.tfstate.backup.$(date +%Y%m%d)
```

### Update Workflow

```bash
# 1. Modify Terraform files
nano main-ha.tf

# 2. Format and validate
terraform fmt -recursive .
terraform validate

# 3. Plan changes
terraform plan -var-file="prod.tfvars" -out=tfplan

# 4. Review
terraform show tfplan

# 5. Apply
terraform apply tfplan

# 6. Verify state
terraform refresh
terraform output
```

### Scaling Workflow

```bash
# 1. Update variables
terraform apply -var="pgbouncer_replicas=3" -var="pg_node_memory_mb=8192"

# OR update tfvars file
echo "pgbouncer_replicas = 3" >> terraform.tfvars

# 2. Plan
terraform plan

# 3. Review resource additions
terraform plan 2>&1 | grep "# docker_container"

# 4. Apply
terraform apply -auto-approve

# 5. Verify scaling
docker ps --filter "name=pgbouncer" | wc -l
```

### Disaster Recovery

```bash
# 1. State backup exists
ls -la terraform.tfstate.backup*

# 2. Restore if needed
cp terraform.tfstate.backup.20260318 terraform.tfstate

# 3. Sync with infrastructure
terraform refresh

# 4. Plan to see current state vs desired
terraform plan

# 5. If all matches, no changes needed
terraform plan 2>&1 | grep "No changes"
```

---

## Best Practices

### State Management
```bash
# ✓ DO: Backup state regularly
backup_state() {
  cp terraform.tfstate terraform.tfstate.backup.$(date +%Y%m%d_%H%M%S)
}

# ✗ DON'T: Never delete state directly
rm terraform.tfstate  # NEVER!

# ✓ DO: Use remote state for team environments
terraform init -backend-config="bucket=my-state" -reconfigure
```

### Variable Security
```bash
# ✓ DO: Use .terraform.tfvars for sensitive values
echo "postgres_password = \"SecurePass123456\"" >> .terraform.tfvars
echo ".terraform.tfvars" >> .gitignore

# ✗ DON'T: Commit passwords to git
git status  # Verify no secrets exposed

# ✓ DO: Use environment variables for CI/CD
export TF_VAR_postgres_password="SecurePass123456"
```

### Testing Changes
```bash
# ✓ DO: Always plan before applying
terraform plan -out=tfplan

# ✓ DO: Review plan output carefully
terraform show tfplan | less

# ✓ DO: Test in staging first
terraform workspace select staging
terraform apply tfplan_staging

# ✓ DO: Only then apply to production
terraform workspace select prod
terraform apply tfplan_prod
```

---

**Last Updated:** 2026  
**Version:** Phase 1 Optimized  
**Tested Against:** Terraform 1.0+, Docker Provider 3.0+
