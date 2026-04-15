#!/bin/bash

# ==============================================================================
# WADIGITAL CORE - INSTALADOR MAESTRO MULTIMODAL
# ==============================================================================

clear
echo "======================================================================"
echo "          INSTALADOR MAESTRO WADIGITAL - AGENTE DE VENTAS IA          "
echo "======================================================================"
echo ""

# 1. CAPTURA DE VARIABLES MAESTRAS
read -p "🔹 Ingrese su dominio principal (ej: wadigitalgroup.com): " DOMAIN
read -p "🔹 Ingrese su correo electrónico (para SSL): " EMAIL
read -p "🔹 Ingrese su CLAVE MAESTRA (será la pass de todo): " MASTER_PASS

# 2. PREPARACIÓN DEL SISTEMA Y SEGURIDAD
echo "----------------------------------------------------------------------"
echo "[1/7] Preparando seguridad y dependencias..."
apt update && apt upgrade -y
apt install -y ufw fail2ban curl git jo jq wget
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp
ufw allow 2377/tcp && ufw allow 7946/tcp && ufw allow 4789/udp
echo "y" | ufw enable

# 3. INSTALACIÓN DE DOCKER SWARM
if ! [ -x "$(command -v docker)" ]; then
    curl -fsSL https://get.docker.com | sh
fi
docker swarm init --advertise-addr $(curl -s ifconfig.me) || true

# Crear Redes
docker network create --driver overlay --attachable frontend || true
docker network create --driver overlay --attachable backend || true

# 4. CREACIÓN DE ESTRUCTURA DE PERSISTENCIA
mkdir -p /home/docker/{traefik/data,n8n/local-files,postgres/data,redis/data,evoapi,chatwoot/storage}
touch /home/docker/traefik/data/acme.json
chmod 600 /home/docker/traefik/data/acme.json

# 5. GENERACIÓN DEL ARCHIVO MAESTRO (STACK)
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
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /home/docker/traefik/data/acme.json:/acme.json
    networks: [frontend]
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.api.rule=Host(\`proxy.$DOMAIN\`)"
        - "traefik.http.routers.api.service=api@internal"
        - "traefik.http.routers.api.entrypoints=websecure"
        - "traefik.http.routers.api.tls.certresolver=myresolver"

  postgres:
    image: postgres:15-alpine
    environment:
      - POSTGRES_PASSWORD=$MASTER_PASS
    volumes: [/home/docker/postgres/data:/var/lib/postgresql/data]
    networks: [backend]

  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes --requirepass $MASTER_PASS
    volumes: [/home/docker/redis/data:/data]
    networks: [backend, frontend]

  n8n:
    image: n8nio/n8n:latest
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PASSWORD=$MASTER_PASS
      - N8N_ENCRYPTION_KEY=$MASTER_PASS
      - N8N_HOST=n8n.$DOMAIN
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://n8n.$DOMAIN/
    volumes: [/home/docker/n8n/local-files:/home/node/local-files]
    networks: [frontend, backend]
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.n8n.rule=Host(\`n8n.$DOMAIN\`)"
        - "traefik.http.routers.n8n.entrypoints=websecure"
        - "traefik.http.routers.n8n.tls.certresolver=myresolver"
        - "traefik.http.services.n8n.loadbalancer.server.port=5678"

  evolution:
    image: atendare/evolution-api:latest
    environment:
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_HOST=redis
      - CACHE_REDIS_PASSWORD=$MASTER_PASS
      - DATABASE_ENABLED=true
      - DATABASE_CONNECTION_URI=postgresql://postgres:$MASTER_PASS@postgres:5432/evolution
    networks: [frontend, backend]
    deploy:
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.evo.rule=Host(\`evoapi.$DOMAIN\`)"
        - "traefik.http.routers.evo.entrypoints=websecure"
        - "traefik.http.routers.evo.tls.certresolver=myresolver"
        - "traefik.http.services.evo.loadbalancer.server.port=8080"

networks:
  frontend: { external: true }
  backend: { external: true }
EOF

# 6. DESPLIEGUE SECUENCIAL CON HEALTHCHECK
echo "[2/7] Desplegando Infraestructura Base..."
docker stack deploy -c /home/docker/master-stack.yml wadigital

echo "⏳ Esperando estabilidad de servicios (aprox. 30s)..."
sleep 30

# 7. FINALIZACIÓN Y RESUMEN
echo "======================================================================"
echo "✅ ¡INSTALACIÓN COMPLETADA EXITOSAMENTE!"
echo "======================================================================"
echo "🔗 n8n:        https://n8n.$DOMAIN"
echo "🔗 Evolution:  https://evoapi.$DOMAIN"
echo "🔗 Traefik:    https://proxy.$DOMAIN"
echo ""
echo "🔑 Clave Maestra: $MASTER_PASS"
echo "📂 Datos en: /home/docker/"
echo "======================================================================"
