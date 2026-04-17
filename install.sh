#!/bin/bash
set -e

echo "=== INICIANDO DESPLIEGUE FINAL WADIGITAL ==="
read -p "Dominio (ej: wadigitalgroup.com): " DOMAIN
read -p "Email para SSL: " EMAIL
read -s -p "Clave Maestra: " MASTER_PASS
echo -e "\n"

# El servidor creará una llave de 64 caracteres de forma invisible
CHATWOOT_SECRET=$(openssl rand -hex 32)

# Crear carpetas si no existen
mkdir -p /home/docker/{traefik/data,n8n/local-files,postgres/data,redis/data,chatwoot/storage}

# Crear el archivo maestro
cat <<EOF > /home/docker/master-stack.yml
version: '3.8'
services:
  traefik:
    image: traefik:v2.11
    command:
      - "--api.dashboard=true"
      - "--providers.docker.swarmMode=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--certificatesresolvers.myresolver.acme.httpchallenge=true"
      - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.myresolver.acme.email=$EMAIL"
      - "--certificatesresolvers.myresolver.acme.storage=/acme.json"
    ports: ["80:80", "443:443"]
    volumes: ["/var/run/docker.sock:/var/run/docker.sock:ro", "/home/docker/traefik/data/acme.json:/acme.json"]
    networks: [frontend]
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=frontend"
        - "traefik.http.routers.api.rule=Host(\`proxy.$DOMAIN\`)"
        - "traefik.http.routers.api.service=api@internal"
        - "traefik.http.routers.api.tls.certresolver=myresolver"
        - "traefik.http.routers.api.entrypoints=websecure"

  postgres:
    image: pgvector/pgvector:pg15
    environment:
      - POSTGRES_PASSWORD=$MASTER_PASS
    volumes: ["/home/docker/postgres/data:/var/lib/postgresql/data"]
    networks: [backend]

  redis:
    image: redis:7-alpine
    command: redis-server --requirepass $MASTER_PASS
    networks: [backend]

  n8n:
    image: n8nio/n8n:latest
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_DATABASE=postgres
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=$MASTER_PASS
      - N8N_HOST=n8n.$DOMAIN
      - N8N_PROTOCOL=https
      - NODE_FUNCTION_ALLOW_EXTERNAL=moment,lodash
    volumes: ["/home/docker/n8n/local-files:/home/node/local-files"]
    networks: [frontend, backend]
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=frontend"
        - "traefik.http.routers.n8n.rule=Host(\`n8n.$DOMAIN\`)"
        - "traefik.http.routers.n8n.tls.certresolver=myresolver"
        - "traefik.http.routers.n8n.entrypoints=websecure"
        - "traefik.http.services.n8n.loadbalancer.server.port=5678"

  evolution:
    image: evoapicloud/evolution-api:latest
    environment:
      - DATABASE_PROVIDER=postgresql
      - DATABASE_ENABLED=true
      - DATABASE_CONNECTION_URI=postgresql://postgres:$MASTER_PASS@postgres:5432/postgres
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_HOST=redis
      - CACHE_REDIS_PASSWORD=$MASTER_PASS
    networks: [frontend, backend]
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=frontend"
        - "traefik.http.routers.evo.rule=Host(\`evoapi.$DOMAIN\`)"
        - "traefik.http.routers.evo.tls.certresolver=myresolver"
        - "traefik.http.routers.evo.entrypoints=websecure"
        - "traefik.http.services.evo.loadbalancer.server.port=8080"

  chatwoot:
    image: chatwoot/chatwoot:latest
    command: ["bundle", "exec", "rails", "s", "-p", "3000", "-b", "0.0.0.0"]
    environment:
      - NODE_ENV=production
      - RAILS_ENV=production
      - INSTALLATION_ENV=docker
      - SECRET_KEY_BASE=$CHATWOOT_SECRET
      - FRONTEND_URL=https://chat.$DOMAIN
      - POSTGRES_HOST=postgres
      - POSTGRES_USERNAME=postgres
      - POSTGRES_PASSWORD=$MASTER_PASS
      - POSTGRES_DATABASE=postgres
      - REDIS_URL=redis://:$MASTER_PASS@redis:6379/0
    volumes: ["/home/docker/chatwoot/storage:/app/storage"]
    networks: [frontend, backend]
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=frontend"
        - "traefik.http.routers.chat.rule=Host(\`chat.$DOMAIN\`)"
        - "traefik.http.routers.chat.tls.certresolver=myresolver"
        - "traefik.http.routers.chat.entrypoints=websecure"
        - "traefik.http.services.chat.loadbalancer.server.port=3000"

  chatwoot-worker:
    image: chatwoot/chatwoot:latest
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
    environment:
      - NODE_ENV=production
      - RAILS_ENV=production
      - INSTALLATION_ENV=docker
      - SECRET_KEY_BASE=$CHATWOOT_SECRET
      - FRONTEND_URL=https://chat.$DOMAIN
      - POSTGRES_HOST=postgres
      - POSTGRES_USERNAME=postgres
      - POSTGRES_PASSWORD=$MASTER_PASS
      - POSTGRES_DATABASE=postgres
      - REDIS_URL=redis://:$MASTER_PASS@redis:6379/0
    volumes: ["/home/docker/chatwoot/storage:/app/storage"]
    networks: [backend]

networks:
  frontend: { external: true }
  backend: { external: true }
EOF

# Lanzar al orquestador
docker stack deploy -c /home/docker/master-stack.yml wadigital
echo "¡Despliegue finalizado!"
