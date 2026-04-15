#!/bin/bash
# WADIGITAL CORE v2.5 - FINAL RELEASE
set -e

# 1. Limpieza de instalaciones fallidas previas
echo "Limpiando rastro de instalaciones anteriores..."
docker stack rm wadigital 2>/dev/null || true
sleep 2

# 2. Captura de datos
read -p "Dominio (ej: wadigital.com): " DOMAIN
read -p "Email: " EMAIL
read -s -p "Clave Maestra: " MASTER_PASS
echo ""

# 3. Infraestructura
apt update && apt install -y ufw curl jq
ufw allow 22,80,443,2377,7946,4789/tcp && ufw allow 7946,4789/udp
echo "y" | ufw enable

# Docker & Redes
if ! [ -x "$(command -v docker)" ]; then curl -fsSL https://get.docker.com | sh; fi
docker swarm init --advertise-addr $(curl -s ifconfig.me) || true
docker network create --driver overlay --attachable frontend || true
docker network create --driver overlay --attachable backend || true

# 4. Directorios
mkdir -p /home/docker/{traefik/data,n8n/local-files,postgres/data,redis/data,evoapi}
touch /home/docker/traefik/data/acme.json && chmod 600 /home/docker/traefik/data/acme.json

# 5. Generar Stack (Nota las barras \ antes de las comillas invertidas)
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
        - "traefik.http.routers.api.rule=Host(\`proxy.$DOMAIN\`)"
        - "traefik.http.routers.api.service=api@internal"
        - "traefik.http.routers.api.tls.certresolver=myresolver"
        - "traefik.http.routers.api.entrypoints=websecure"

  postgres:
    image: postgres:15-alpine
    environment: [POSTGRES_PASSWORD=$MASTER_PASS]
    volumes: [/home/docker/postgres/data:/var/lib/postgresql/data]
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
      - DB_POSTGRESDB_PASSWORD=$MASTER_PASS
      - N8N_HOST=n8n.$DOMAIN
      - N8N_PROTOCOL=https
      - NODE_FUNCTION_ALLOW_EXTERNAL=moment,lodash
    volumes: [/home/docker/n8n/local-files:/home/node/local-files]
    networks: [frontend, backend]
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.n8n.rule=Host(\`n8n.$DOMAIN\`)"
        - "traefik.http.routers.n8n.tls.certresolver=myresolver"
        - "traefik.http.routers.n8n.entrypoints=websecure"
        - "traefik.http.services.n8n.loadbalancer.server.port=5678"

  evolution:
    image: atendare/evolution-api:latest
    environment:
      - DATABASE_ENABLED=true
      - DATABASE_CONNECTION_URI=postgresql://postgres:$MASTER_PASS@postgres:5432/postgres
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_HOST=redis
      - CACHE_REDIS_PASSWORD=$MASTER_PASS
    networks: [frontend, backend]
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.evo.rule=Host(\`evoapi.$DOMAIN\`)"
        - "traefik.http.routers.evo.tls.certresolver=myresolver"
        - "traefik.http.routers.evo.entrypoints=websecure"
        - "traefik.http.services.evo.loadbalancer.server.port=8080"
networks:
  frontend: { external: true }
  backend: { external: true }
EOF

docker stack deploy -c /home/docker/master-stack.yml wadigital
echo "SISTEMA LISTO EN: https://n8n.$DOMAIN"
