#!/bin/bash

# ==============================================================================
# WADIGITAL CORE - INSTALADOR MAESTRO (v2.0)
# Optimizando para: saulcordi01-max/vps-deploy
# ==============================================================================

set -e # Detener si hay errores

# Colores
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${BLUE}======================================================================"
echo -e "          INICIANDO DESPLIEGUE MAESTRO: WADIGITAL CORE          "
echo -e "======================================================================${NC}"

# 1. VERIFICACIÓN DE PERMISOS
if [[ $EUID -ne 0 ]]; then
   echo -e "${YELLOW}❌ Debes ejecutar como root (usa sudo).${NC}" 
   exit 1
fi

# 2. ENTRADA DE DATOS
echo -e "${GREEN}▶ CONFIGURACIÓN GLOBAL:${NC}"
read -p "   Dominio (ej: wadigitalgroup.com): " DOMAIN
read -p "   Email para Certificados SSL: " EMAIL
read -s -p "   Clave Maestra (DB/Admin): " MASTER_PASS
echo -e "\n"

# 3. PREPARACIÓN DEL SISTEMA (Hardening & Utils)
echo -e "${BLUE}[1/6] Preparando entorno y seguridad...${NC}"
apt update && apt install -y ufw fail2ban curl jq jo git wget sed
ufw allow 22,80,443,2377,7946,4789/tcp
ufw allow 7946,4789/udp
echo "y" | ufw enable

# 4. DOCKER SWARM ENGINE
echo -e "${BLUE}[2/6] Instalando Motor Docker y Swarm...${NC}"
if ! [ -x "$(command -v docker)" ]; then
    curl -fsSL https://get.docker.com | sh
fi
docker swarm init --advertise-addr $(curl -s ifconfig.me) || true

# Crear Redes Overlay (Aislamiento de Zonas)
docker network create --driver overlay --attachable frontend || true
docker network create --driver overlay --attachable backend || true

# 5. ESTRUCTURA DE DIRECTORIOS (Persistencia Real)
echo -e "${BLUE}[3/6] Creando volúmenes de persistencia...${NC}"
mkdir -p /home/docker/{traefik/data,n8n/local-files,postgres/data,redis/data,evoapi,chatwoot/storage}
touch /home/docker/traefik/data/acme.json
chmod 600 /home/docker/traefik/data/acme.json

# 6. GENERACIÓN DEL ARCHIVO DE DESPLIEGUE (master-stack.yml)
echo -e "${BLUE}[4/6] Generando Orquestador de Servicios...${NC}"

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
        - "traefik.http.routers.api.tls.certresolver=myresolver"
        - "traefik.http.routers.api.entrypoints=websecure"

  postgres:
    image: postgres:15-alpine
    environment:
      - POSTGRES_PASSWORD=$MASTER_PASS
      - POSTGRES_DB=wadigital_db
    volumes: [/home/docker/postgres/data:/var/lib/postgresql/data]
    networks: [backend]

  redis:
    image: redis:7-alpine
    command: redis-server --requirepass $MASTER_PASS
    volumes: [/home/docker/redis/data:/data]
    networks: [backend]

  n8n:
    image: n8nio/n8n:latest
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=wadigital_db
      - DB_POSTGRESDB_USER=postgres
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
      - DATABASE_CONNECTION_URI=postgresql://postgres:$MASTER_PASS@postgres:5432/wadigital_db
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

# 7. DESPLIEGUE
echo -e "${BLUE}[5/6] Lanzando servicios al Swarm...${NC}"
docker stack deploy -c /home/docker/master-stack.yml wadigital

# 8. MENSAJE FINAL
echo -e "${GREEN}======================================================================"
echo -e "✅ ¡SISTEMA DESPLEGADO EXITOSAMENTE!"
echo -e "======================================================================"
echo -e "🚀 n8n:        https://n8n.$DOMAIN"
echo -e "🚀 Evolution:  https://evoapi.$DOMAIN"
echo -e "🚀 Proxy:      https://proxy.$DOMAIN"
echo -e "----------------------------------------------------------------------"
echo -e "🔑 Password:   $MASTER_PASS"
echo -e "📂 Base Dir:   /home/docker/"
echo -e "======================================================================${NC}"
