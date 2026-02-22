#!/bin/bash
# (c) AlexVDem
# Function to generate random strings (0-9, ABCDF)
generate_random_string() {
    local LENGTH=${1:-16}
    local CHARSET="0123456789ABCDFabcdf"
    local STRING=""
    for ((i=1; i<=LENGTH; i++)); do
        local CHAR=$(head /dev/urandom | tr -dc "$CHARSET" | head -c 1)
        STRING="${STRING}${CHAR}"
    done
    echo "$STRING"
}

# --- CHECK REQUIREMENTS ---
echo "=== Checking system requirements ==="
MISSING_DEP=0

# Check for binaries
for cmd in docker docker-compose python3 sudo; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "WARNING: '$cmd' is not installed. Please install it."
        MISSING_DEP=1
    fi
done

# Extract DOMAIN_NAME for SSL certificate check
CHECK_DOMAIN="matrix.example.com"
if [ -f .env ]; then
    CHECK_DOMAIN=$(grep "^DOMAIN_NAME=" .env | cut -d'=' -f2-)
fi
CHECK_DOMAIN=${CHECK_DOMAIN:-matrix.example.com}

# Check for SSL certificates or placeholder domain
if [ "$CHECK_DOMAIN" == "matrix.example.com" ]; then
    echo "WARNING: DOMAIN_NAME is set to the default 'matrix.example.com'. Please change it in your .env file to your actual domain name."
    MISSING_DEP=1
else
    FULLCHAIN="/etc/letsencrypt/live/$CHECK_DOMAIN/fullchain.pem"
    PRIVKEY="/etc/letsencrypt/live/$CHECK_DOMAIN/privkey.pem"

    if [ ! -f "$FULLCHAIN" ]; then
        echo "WARNING: SSL certificate not found at $FULLCHAIN"
        MISSING_DEP=1
    fi

    if [ ! -f "$PRIVKEY" ]; then
        echo "WARNING: SSL private key not found at $PRIVKEY"
        MISSING_DEP=1
    fi
fi

if [ $MISSING_DEP -eq 1 ]; then
    echo "WARNING: Some requirements are missing. Please ensure all dependencies are met for correct operation."
    read -p "Do you want to proceed anyway? (y/N) " confirm_reqs
    if [[ ! "$confirm_reqs" =~ ^[Yy]$ ]]; then
        echo "Aborting setup."
        exit 1
    fi
fi
# --------------------------

echo "=== Synapse Server Auto-Configuration (Full Rebuild from Script) ==="

# --- SAFETY CHECK ---
if [ -f docker-compose.yml ] || [ -d data ]; then
    echo "WARNING: Configuration or data already exists in this directory."
    echo "Running this script will REGENERATE ALL SECRETS and might break your existing server."
    read -p "Are you sure you want to proceed? (y/N) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborting setup."
        exit 1
    fi
fi

# Load user-provided values from .env
if [ -f .env ]; then
    DOMAIN_NAME=$(grep "^DOMAIN_NAME=" .env | cut -d'=' -f2-)
    FEDERATION_DOMAIN_WHITELIST=$(grep "^FEDERATION_DOMAIN_WHITELIST=" .env | cut -d'=' -f2- | tr -d '"')
    MAX_UPLOAD_SIZE=$(grep "^MAX_UPLOAD_SIZE=" .env | cut -d'=' -f2-)
fi

DOMAIN_NAME=${DOMAIN_NAME:-matrix.example.com}
FEDERATION_DOMAIN_WHITELIST=${FEDERATION_DOMAIN_WHITELIST:-matrix.org}
MAX_UPLOAD_SIZE=${MAX_UPLOAD_SIZE:-10M}

echo "=== 1. Generating automatic parameters ==="
PG_USER=$(generate_random_string 16)
PG_PASS=$(generate_random_string 16)
PG_DB=$(generate_random_string 16)
RED_PASS=$(generate_random_string 16)
LK_KEY=$(generate_random_string 16)
LK_SECRET=$(generate_random_string 32)
REG_SECRET=$(generate_random_string 16)

echo "=== 2. Recreating folder structure and template files ==="
mkdir -p data/synapse data/postgres data/certs nginx

# --- TEMPLATE: docker-compose.yml ---
cat > docker-compose.yml <<EOF
version: '3.8'
services:
  db:
    image: postgres:15-alpine
    restart: always
    environment:
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${PG_PASS}
      POSTGRES_DB: ${PG_DB}
      POSTGRES_INITDB_ARGS: "--lc-collate=C --lc-ctype=C --encoding=UTF8"
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - matrix-network
  redis:
    image: redis:7-alpine
    restart: always
    command: redis-server --requirepass ${RED_PASS}
    networks:
      - matrix-network
  synapse:
    image: matrixdotorg/synapse:latest
    restart: always
    volumes:
      - ./data/synapse:/data
    working_dir: /data
    depends_on:
      - db
      - redis
    networks:
      - matrix-network
  element:
    image: vectorim/element-web:latest
    restart: always
    volumes:
      - ./element-config.json:/app/config.json:ro
    networks:
      - matrix-network
  nginx:
    image: nginx:alpine
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx:/etc/nginx/conf.d:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - synapse
      - element
      - auth-service
      - livekit
    networks:
      - matrix-network
  auth-service:
    image: ghcr.io/element-hq/lk-jwt-service:latest
    container_name: element-call-jwt
    hostname: auth-server
    environment:
      - LK_JWT_PORT=8080
      - LIVEKIT_URL=https://${DOMAIN_NAME}/livekit/sfu
      - LIVEKIT_KEY=${LK_KEY}
      - LIVEKIT_SECRET=${LK_SECRET}
    restart: unless-stopped
    ports:
      - 8070:8080
    networks:
      - matrix-network
  livekit:
    image: livekit/livekit-server:latest
    container_name: element-call-livekit
    command: --config /etc/livekit.yaml
    ports:
      - 7880:7880/tcp
      - 7881:7881/tcp
      - 7882:7882/tcp
      - 50100-50200:50100-50200/udp
    restart: unless-stopped
    volumes:
      - ./config.yaml:/etc/livekit.yaml:ro
    networks:
      - matrix-network
networks:
  matrix-network:
    driver: bridge
EOF

# --- TEMPLATE: config.yaml ---
cat > config.yaml <<EOF
port: 7880
bind_addresses:
  - "0.0.0.0"
rtc:
  tcp_port: 7881
  port_range_start: 50100
  port_range_end: 50200
  use_external_ip: false
logging:
  level: info
turn:
  enabled: false
  domain: localhost
  cert_file: ""
  key_file: ""
  tls_port: 5349
  udp_port: 443
  external_tls: true
keys:
  ${LK_KEY}: "${LK_SECRET}"
EOF

# --- TEMPLATE: element-config.json ---
cat > element-config.json <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://${DOMAIN_NAME}",
            "server_name": "${DOMAIN_NAME}"
        }
    },
    "features": {
        "feature_group_calls": true,
        "feature_video_rooms": true,
        "feature_element_call_msc3401": true
    },
    "element_call": {
        "url": "https://${DOMAIN_NAME}",
        "use_exclusively": true,
        "participant_limit": 8
    }
}
EOF

# --- TEMPLATE: nginx/matrix.conf ---
cat > nginx/matrix.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN_NAME};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    location / {
        proxy_pass http://element:80;
    }
    location ~ ^/(?|(_matrix|_synapse/client)) {
        proxy_pass http://synapse:8008;
        client_max_body_size ${MAX_UPLOAD_SIZE};
    }
    location /.well-known/matrix/client {
        return 200 '{"m.homeserver": {"base_url": "https://${DOMAIN_NAME}"}, "org.matrix.msc4143.rtc_foci": [{"type": "livekit", "livekit_service_url": "https://${DOMAIN_NAME}"}], "io.element.group_call": {"enabled": true}}';
        add_header Content-Type application/json;
        add_header "Access-Control-Allow-Origin" *;
    }
    location /.well-known/matrix/server {
        return 200 '{"m.server": "${DOMAIN_NAME}:443"}';
        add_header Content-Type application/json;
        add_header "Access-Control-Allow-Origin" *;
    }
    location /sfu/get {
        proxy_pass http://auth-service:8080/sfu/get;
    }
    location /livekit/sfu/ {
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_pass http://livekit:7880/;
    }
}
EOF

# --- TEMPLATE: homeserver.yaml ---
cat > data/synapse/homeserver.yaml <<EOF
server_name: "${DOMAIN_NAME}"
report_stats: false
max_upload_size: "${MAX_UPLOAD_SIZE}"
pid_file: /data/homeserver.pid
listeners:
  - port: 8008
    resources:
    - compress: false
    - names: [client, federation]
    tls: false
    type: http
    x_forwarded: true
database:
  name: psycopg2
  args:
    user: ${PG_USER}
    password: ${PG_PASS}
    database: ${PG_DB}
    host: db
    cp_min: 5
    cp_max: 10
redis:
  enabled: true
  host: redis
  port: 6379
  password: ${RED_PASS}
serve_server_wellknown: true
registration_shared_secret: "${REG_SECRET}"
experimental_features:
  msc3266_enabled: true
  msc4222_enabled: true
  msc3401_enabled: true
  msc3026_enabled: true
element_call:
  url: "http://auth-service:8080"
  api_key: "${LK_KEY}"
  api_secret: "${LK_SECRET}"
EOF

# Federation Whitelist update using Python
python3 -c "
import sys
config_path = sys.argv[1]
whitelist = [d.strip() for d in sys.argv[2].split(',') if d.strip()]
with open(config_path, 'r') as f: lines = f.readlines()
new_lines = []
for line in lines:
    new_lines.append(line)
    if 'serve_server_wellknown:' in line:
        new_lines.append('federation_domain_whitelist:\n')
        for d in whitelist: new_lines.append(f'  - {d}\n')
with open(config_path, 'w') as f: f.writelines(new_lines)
" "data/synapse/homeserver.yaml" "$FEDERATION_DOMAIN_WHITELIST"

echo "=== 3. Finalizing permissions ==="
sudo chown -R 991:991 data/synapse 2>/dev/null
sudo chmod -R 777 data/postgres 2>/dev/null

echo "========================================================="
echo "Configuration REBUILT for ${DOMAIN_NAME}"
echo "Launch with: docker-compose up -d"
echo "========================================================="
