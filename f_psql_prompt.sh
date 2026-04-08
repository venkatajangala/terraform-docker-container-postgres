#!/bin/bash

# Function to connect to PostgreSQL using psql client within Docker containers
# Usage:
#   f_psql_prompt [PgBouncerPSQL|ServerPSQL] [optional: username]
# Example:
#   f_psql_prompt PgBouncerPSQL postgres
#   f_psql_prompt ServerPSQL postgres

f_psql_prompt() {

# Function to display usage instructions
   Usage(){
        echo 
        echo "Usage:"
        echo "  f_psql_prompt [PgBouncerPSQL|ServerPSQL] [optional: username]"
        echo
        echo "Example:"
        echo "  f_psql_prompt PgBouncerPSQL postgres"
        echo "  f_psql_prompt ServerPSQL postgres"
        echo
   } 

# Navigate to the directory containing the Terraform configuration to access the output variables
  cd ~/terraform-docker-container-postgres

  echo
  echo "PSQL Prompt - Connect to PostgreSQL using psql client within Docker containers."
  echo "Connecting Via $1..."
  echo

# Set default username if not provided
  if [ -z "$2" ]; then
    export PGUSER="pgadmin"
  else
    export PGUSER="$2"
  fi

# check if the provided option is valid and execute the corresponding command
  case "$1" in
    "PgBouncerPSQL")
        export PGPASSWORD="$(terraform output generated_passwords | grep db_admin | cut -d '=' -f 2 | cut -d '"' -f 2)"
        docker exec -it pgbouncer-1 bash -c "PGPASSWORD='$PGPASSWORD' PGUSER='$PGUSER' psql -h localhost -p 6432 -U $PGUSER -d postgres"
      ;;
    "ServerPSQL")
      export PGPASSWORD="$(terraform output generated_passwords | grep db_admin | cut -d '=' -f 2 | cut -d '"' -f 2)"
      export PGHOST=$(docker exec pg-node-1 bash -c "/usr/local/bin/patronictl -c /etc/patroni/patroni.yml list | grep Leader | cut -d '|' -f 2 | tr -d '[:space:]'")
      docker exec -it $PGHOST bash -c "PGPASSWORD='$PGPASSWORD' PGUSER='$PGUSER' psql -h localhost -p 5432 -U $PGUSER -d postgres"
      ;;
    *)
      echo
      echo "ERROR: Invalid option. Please choose 'PgBouncerPSQL' or 'ServerPSQL'."
      Usage
      ;;
  esac

# Return to the home directory after execution
  cd ~

} # f_psql_prompt

# Example usage of the function
echo "Call:"
echo "f_psql_prompt"
echo
