#!/bin/bash
############################################################
# Script Name:      setup-webhook.sh
# Author:           Giovanni Trujillo Silvas (gtrujill0@outlook.com)
# Created:          2025-05-21
# Last Modified:    2025-06-11
# Description:      Automatiza la configuración de webhooks
# License:          MIT
############################################################

set -euo pipefail
# Asignacion de variables
BRANCH=${1:-main}
OWNER_USER="root"

# Obtener nombre de la app basado en la carpeta
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# BASE_DIR es una carpeta atrás de donde está el script (la raíz del proyecto)
BASE_DIR="$(dirname "$SCRIPT_DIR")"

APP_ID="webhook-$(basename "$BASE_DIR" | sed 's/[^a-zA-Z0-9_]/_/g')"

# Valida si la rama es diferente de main para concatener al ID de la app
if [ "$BRANCH" != "main" ]; then
  APP_ID="${APP_ID}-${BRANCH}"
fi

# Rutas principales
HOOKS_DIR="/opt/hooks"
HOOKS_FILE="$HOOKS_DIR/hooks.json"
DEPLOY_SCRIPT="$HOOKS_DIR/${APP_ID}.sh"
ENV_FILE="$HOOKS_DIR/.env"
SERVICE_FILE="/etc/systemd/system/webhook.service"
LOG_FILE="$HOOKS_DIR/logs/${APP_ID}.log"

# Validar herramientas necesarias
for cmd in git docker docker-compose jq openssl; do
  if ! command -v $cmd &> /dev/null; then
    echo "❌ '$cmd' no está instalado. Instalalo antes de continuar."
    exit 1
  fi
done

if id "sistemasweb" &>/dev/null; then
    OWNER_USER="sistemasweb"
fi

# Crear directorios necesarios
sudo mkdir -p "$HOOKS_DIR/logs"
sudo chown "$OWNER_USER":"$OWNER_USER" "$HOOKS_DIR/logs"
sudo chmod 755 "$HOOKS_DIR/logs"

# Evitar sobreescribir hook ya existente
if [[ -e "$DEPLOY_SCRIPT" ]]; then
  echo "❌ El webhook ${APP_ID} ya existe."
  exit 1
fi

# Crear script de redeploy para esta app
cat > "$DEPLOY_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail

LOGFILE="${LOG_FILE}"
MAX_SIZE=10000
PROJECT_DIR="${BASE_DIR}"

mkdir -p "\$(dirname "\$LOGFILE")"
touch "\$LOGFILE"
chmod 644 "\$LOGFILE"

# Rotar log si supera tamaño
if [ -f "\$LOGFILE" ] && [ "\$(stat -c%s "\$LOGFILE")" -ge "\$MAX_SIZE" ]; then
  mv "\$LOGFILE" "\${LOGFILE}.\$(date +%Y%m%d%H%M%S).old"
  touch "\$LOGFILE"
  chmod 644 "\$LOGFILE"
fi

# Registrar inicio del redeploy
{
  echo ""
  echo "------------------------------------------------------------------------------------------------------"
  echo "📅 \$(date '+%Y-%m-%d %H:%M:%S') - Iniciando redeploy"
  echo "------------------------------------------------------------------------------------------------------"
} >> "\$LOGFILE"

cd "\$PROJECT_DIR" || {
  echo "❌ \$(date '+%Y-%m-%d %H:%M:%S') - No se pudo cambiar al directorio \$PROJECT_DIR" >> "\$LOGFILE"
  exit 1
}

{
  echo "➡️  Haciendo pull de cambios desde Git..."
  if ! git checkout ${BRANCH} >> "\$LOGFILE" 2>&1; then
    echo "❌ Error en git checkout " >> "\$LOGFILE"
    exit 1
  fi

  echo "➡️  Haciendo pull de cambios desde Git..."
  if ! git pull origin ${BRANCH} >> "\$LOGFILE" 2>&1; then
    echo "❌ Error en git pull " >> "\$LOGFILE"
    exit 1
  fi

  echo "➡️  Apagando contenedores Docker..."
  if ! docker compose down >> "\$LOGFILE" 2>&1; then
    echo "❌ Error al bajar contenedores Docker" >> "\$LOGFILE"
    exit 1
  fi

  echo "➡️  Reconstruyendo y levantando contenedores Docker..."
  if ! docker compose up -d --build >> "\$LOGFILE" 2>&1; then
    echo "❌ Error al levantar contenedores Docker" >> "\$LOGFILE"
    exit 1
  fi

  echo "✅ Despliegue completado correctamente."
  echo "------------------------------------------------------------------------------------------------------"
  echo ""
} >> "\$LOGFILE"

exit 0
EOF

chmod +x "$DEPLOY_SCRIPT"
sudo chmod +x "$DEPLOY_SCRIPT"
sudo chown "$OWNER_USER":"$OWNER_USER" "$DEPLOY_SCRIPT"

# Crear o reutilizar token en .env
if [ ! -f "$ENV_FILE" ]; then
    echo "🔐 Generando token secreto..."
    SECRET_TOKEN=$(openssl rand -hex 32)
    echo "SECRET_TOKEN=$SECRET_TOKEN" | sudo tee "$ENV_FILE" > /dev/null
else
    SECRET_TOKEN=$(grep SECRET_TOKEN "$ENV_FILE" | cut -d '=' -f2)
    echo "🔐 Usando token existente."
fi

# Crear hook JSON para esta app
NEW_HOOK=$(jq -n \
  --arg id "$APP_ID" \
  --arg cmd "$DEPLOY_SCRIPT" \
  --arg dir "$HOOKS_DIR" \
  --arg token "$SECRET_TOKEN" \
  '{
    id: $id,
    "execute-command": $cmd,
    "command-working-directory": $dir,
    "response-message": "Deploy ejecutado"
  }')

# Actualizar hooks.json (crear o actualizar hook)
if [ -f "$HOOKS_FILE" ]; then
  if sudo jq -e --arg id "$APP_ID" '.[] | select(.id == $id)' "$HOOKS_FILE" > /dev/null; then
    echo "🔄 Actualizando hook existente..."
    TEMP_HOOKS=$(mktemp)
    sudo jq --argjson hook "$NEW_HOOK" --arg id "$APP_ID" \
      'map(if .id == $id then $hook else . end)' "$HOOKS_FILE" > "$TEMP_HOOKS" && sudo mv "$TEMP_HOOKS" "$HOOKS_FILE"
  else
    echo "➕ Agregando nuevo hook..."
    TEMP_HOOKS=$(mktemp)
    sudo jq ". += [$NEW_HOOK]" "$HOOKS_FILE" > "$TEMP_HOOKS" && sudo mv "$TEMP_HOOKS" "$HOOKS_FILE"
  fi
else
  echo "📄 Creando hooks.json..."
  echo "[$NEW_HOOK]" | sudo tee "$HOOKS_FILE" > /dev/null
fi

# Instalar webhook si no está instalado
if ! command -v webhook &> /dev/null; then
    echo "📦 Instalando webhook..."
    sudo apt install webhook -y
fi

# Crear servicio systemd global si no existe
if [ ! -f "$SERVICE_FILE" ]; then
  echo "🛠️ Creando servicio systemd global webhook..."
  sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Webhook listener global para Git auto-deploy
After=network.target
Requires=network.target

[Service]
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/webhook -hooks ${HOOKS_FILE} -port 60001
WorkingDirectory=${HOOKS_DIR}
Restart=always
RestartSec=3
User=${OWNER_USER}
KillMode=process
ExecReload=/bin/kill -HUP \$MAINPID
StandardOutput=journal
StandardError=journal
SyslogIdentifier=webhook

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable webhook.service
fi

# Se añade directorio como un "safe directory" para Git
sudo -u "$OWNER_USER" git config --global --add safe.directory "$BASE_DIR"

sudo chown "$OWNER_USER":"$OWNER_USER" $HOOKS_DIR
sudo chown "$OWNER_USER":"$OWNER_USER" $SERVICE_FILE
# Reiniciar servicio para cargar nuevo hook
echo "🔄 Reiniciando servicio webhook para aplicar cambios..."
sudo systemctl restart webhook.service

# Se optiene la IP pública del servidor
IP_PUBLICA=$(curl -s ipinfo.io/ip)

# Mensajes finales
echo ""
echo "✅ Webhook $APP_ID configurado y corriendo en puerto 60100."
echo "🔐 Token secreto: $SECRET_TOKEN"
echo ""
echo "Puedes probarlo con:"
echo "curl -X POST http://$IP_PUBLICA:60100/hooks/$APP_ID \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -H 'X-Hub-Token: $SECRET_TOKEN' \\"
echo "     -d '{\"ref\": \"refs/heads/main\"}'"
