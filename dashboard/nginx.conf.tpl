server {
    listen 80;
    server_name localhost;

    # Use Docker's embedded DNS so upstream hostnames resolve at request time,
    # not at nginx startup — containers that aren't running return 502 instead
    # of preventing nginx from starting.
    resolver 127.0.0.11 valid=10s ipv6=off;

    # Static dashboard
    location / {
        root /usr/share/nginx/html;
        index index.html;
    }

    # Patroni REST API
    location /api/cluster {
        set $up pg-node-1:8008;
        proxy_pass http://$up/cluster;
        add_header Cache-Control "no-store";
    }

    location /api/leader {
        set $up pg-node-1:8008;
        proxy_pass http://$up/leader;
        add_header Cache-Control "no-store";
    }

    # etcd
    location /api/etcd {
        set $up etcd:2379;
        proxy_pass http://$up/health;
        add_header Cache-Control "no-store";
    }

    # Vault — returns 200/429/503 all with JSON bodies; keep original status code
    location /api/vault {
        set $up vault:${vault_port};
        proxy_pass http://$up/v1/sys/health;
        proxy_intercept_errors off;
        add_header Cache-Control "no-store";
    }

    # Datadog Agent health
    location /api/datadog {
        set $up datadog-agent:5555;
        proxy_pass http://$up/;
        add_header Cache-Control "no-store";
    }
}
