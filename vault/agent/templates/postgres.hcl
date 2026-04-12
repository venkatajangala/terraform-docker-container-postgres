{{ with secret "secret/data/pg/postgres" }}
POSTGRES_USER={{ .Data.data.postgres_user }}
POSTGRES_PASSWORD={{ .Data.data.postgres_password }}
{{ end }}
{{ with secret "secret/data/pg/replication" }}
REPLICATION_PASSWORD={{ .Data.data.replication_password }}
{{ end }}
