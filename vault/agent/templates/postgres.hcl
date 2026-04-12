{{ with secret "kv/data/postgres" }}
POSTGRES_USER={{ .Data.data.postgres_user }}
POSTGRES_PASSWORD={{ .Data.data.postgres_password }}
REPLICATION_PASSWORD={{ .Data.data.replication_password }}
{{ end }}
