#!/bin/bash

# --- CONFIGURACIÓN INICIAL ---
clear
echo "========================================================="
echo "   INSTALADOR AUTOMÁTICO: STACK EMPRENDE-TECH            "
echo "========================================================="

# Pedir datos básicos
read -p "Introduce tu DOMINIO (ej: tudominio.com): " DOMAIN
read -p "Introduce tu EMAIL (para SSL): " EMAIL
read -s -p "Crea una CLAVE para Base de Datos y Admin: " MASTER_PW
echo ""

# 1. Preparación del Sistema
echo "--- 1/5 Instalando Docker y Dependencias ---"
apt update && apt upgrade -y
apt install -y curl git apache2-utils
curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh

# 2. Configuración de Red y Seguridad
echo "--- 2/5 Configurando Red y SSL ---"
docker network create proxy-network
mkdir -p /opt/stacks/traefik-data
touch /opt/stacks/traefik-data/acme.json
chmod 600 /opt/stacks/traefik-data/acme.json
TRAEFIK_AUTH=$(htpasswd -nB admin | sed -e 's/\$/\$\$/g') # Usuario: admin

# 3. Creación del archivo Docker Compose Maestro
echo "--- 3/5 Generando Configuración Global ---"
cat <<EOF > /opt/stacks/docker-compose.yml
version: '3.8'

services:
  # PROXY INVERSO Y SSL
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: always
    networks: [proxy-network]
    ports: [- "80:80", - "443:443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/stacks/traefik-data/acme.json:/acme.json
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.myresolver.acme.tlschallenge=true"
      - "--certificatesresolvers.myresolver.acme.email=$EMAIL"
      - "--certificatesresolvers.myresolver.acme.storage=acme.json"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\`traefik.$DOMAIN\`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=myresolver"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.middlewares.traefik-auth.basicauth.users=admin:$TRAEFIK_AUTH"
      - "traefik.http.routers.traefik.middlewares=traefik-auth"

  # BASES DE DATOS
  postgres:
    image: postgres:15-alpine
    container_name: postgres_db
    restart: always
    networks: [proxy-network]
    environment:
      POSTGRES_USER: admin
      POSTGRES_PASSWORD: $MASTER_PW
    volumes: [- db_data:/var/lib/postgresql/data]

  redis:
    image: redis:7-alpine
    container_name: redis_cache
    restart: always
    networks: [proxy-network]

  # HERRAMIENTAS
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n_app
    restart: always
    networks: [proxy-network]
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres_db
      - DB_POSTGRESDB_PASSWORD=$MASTER_PW
      - N8N_HOST=n8n.$DOMAIN
      - WEBHOOK_URL=https://n8n.$DOMAIN/
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`n8n.$DOMAIN\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"

  evolution_api:
    image: atendare/evolution-api:latest
    container_name: evolution_api
    restart: always
    networks: [proxy-network]
    environment:
      - SERVER_URL=https://evo.$DOMAIN
      - AUTHENTICATION_API_KEY=$MASTER_PW
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_HOST=redis_cache
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.evo.rule=Host(\`evo.$DOMAIN\`)"
      - "traefik.http.routers.evo.entrypoints=websecure"
      - "traefik.http.routers.evo.tls.certresolver=myresolver"

  chatwoot_web:
    image: chatwoot/chatwoot:latest
    container_name: chatwoot_web
    restart: always
    networks: [proxy-network]
    environment:
      - FRONTEND_URL=https://chat.$DOMAIN
      - POSTGRES_HOST=postgres_db
      - POSTGRES_PASSWORD=$MASTER_PW
      - REDIS_URL=redis://redis_cache:6379/1
      - SECRET_KEY_BASE=$MASTER_PW$MASTER_PW
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.chat.rule=Host(\`chat.$DOMAIN\`)"
      - "traefik.http.routers.chat.entrypoints=websecure"
      - "traefik.http.routers.chat.tls.certresolver=myresolver"

volumes:
  db_data:
EOF

# 4. Despliegue
echo "--- 4/5 Lanzando Contenedores ---"
cd /opt/stacks && docker compose up -d

# 5. Inicialización de Chatwoot (Base de datos)
echo "--- 5/5 Configurando Base de Datos de Chatwoot ---"
sleep 15
docker exec -it chatwoot_web bundle exec rails db:chatwoot_prepare

echo "========================================================="
echo "   ¡TODO LISTO! Accede a tus herramientas: "
echo "   n8n: https://n8n.$DOMAIN"
echo "   Chatwoot: https://chat.$DOMAIN"
echo "   Evolution: https://evo.$DOMAIN"
echo "   Traefik: https://traefik.$DOMAIN (user: admin / pass: $MASTER_PW)"
echo "========================================================="
