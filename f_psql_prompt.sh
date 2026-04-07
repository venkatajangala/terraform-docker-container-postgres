#!/bin/bash

# PSQL Prompt
f_psql_prompt() {

   Usage(){
        echo 
        echo "Usage:"
        echo "  f_psql_prompt [PgBouncerPSQL|ServerPSQL]"
        echo
        echo "Example:"
        echo "  f_psql_prompt PgBouncerPSQL"
        echo "  f_psql_prompt ServerPSQL"
        echo
   } 

  echo
  echo "PSQL Prompt - Connect to PostgreSQL using psql client within Docker containers."
  echo "Connecting Via $1..."
  echo
  cd ~/terraform-docker-container-postgres

  case "$1" in
    "PgBouncerPSQL")
        export PGPASSWORD="$(terraform output generated_passwords | grep db_admin | cut -d '=' -f 2 | cut -d '"' -f 2)"
        docker exec -it pgbouncer-1 bash -c "PGPASSWORD='$PGPASSWORD' psql -h localhost -p 6432 -U pgadmin -d postgres"
      ;;
    "ServerPSQL")
      export PGPASSWORD="$(terraform output generated_passwords | grep db_admin | cut -d '=' -f 2 | cut -d '"' -f 2)"
      export PGHOST=$(docker exec pg-node-1 bash -c "/usr/local/bin/patronictl -c /etc/patroni/patroni.yml list | grep Leader | cut -d '|' -f 2 | tr -d '[:space:]'")
      docker exec -it $PGHOST bash -c "PGPASSWORD='$PGPASSWORD' psql -h localhost -p 5432 -U pgadmin -d postgres"
      ;;
    *)
      echo
      echo "ERROR: Invalid option. Please choose 'PgBouncerPSQL' or 'ServerPSQL'."
      Usage
      ;;
  esac

  cd ~

} # f_psql_prompt

echo "Call:"
echo "f_psql_prompt"
