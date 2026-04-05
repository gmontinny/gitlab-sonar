#!/bin/bash
set -e

GITLAB_URL="http://gitlab:${GITLAB_HTTP_PORT}"
SONAR_URL="http://sonarqube:9000"
SONAR_OLD_PASS="${SONAR_ADMIN_PASSWORD:-admin}"
SONAR_NEW_PASS="${SONAR_NEW_ADMIN_PASSWORD:-S0nar@2024}"
PAT_NAME="${GITLAB_PAT_NAME:-sonarqube-integration}"
PROJECT_KEY="${SONAR_PROJECT_KEY:-meu-projeto}"
PROJECT_NAME="${SONAR_PROJECT_NAME:-Meu Projeto}"
OUTPUT_FILE="/setup-output/setup-result.env"

log() { echo "[setup] $(date '+%H:%M:%S') $1"; }

# ── 1. Aguardar GitLab ──────────────────────────────────────
log "Aguardando GitLab..."
until curl -s "${GITLAB_URL}/users/sign_in" | grep -q 'sign_in' 2>/dev/null; do
  sleep 10
done
log "✔ GitLab pronto"

# ── 2. Ler senha root ───────────────────────────────────────
log "Lendo senha root do GitLab..."
PASS_FILE="/gitlab-config/initial_root_password"
for i in $(seq 1 30); do
  if [ -f "$PASS_FILE" ]; then
    GITLAB_ROOT_PASS=$(grep "^Password:" "$PASS_FILE" | awk '{print $2}')
    [ -n "$GITLAB_ROOT_PASS" ] && break
  fi
  sleep 5
done

if [ -z "$GITLAB_ROOT_PASS" ]; then
  log "✘ Não foi possível obter a senha root"
  exit 1
fi
log "✔ Senha root obtida"

# ── 3. Criar PAT via gitlab-rails runner ─────────────────────
log "Criando Personal Access Token no GitLab..."
PAT_TOKEN="glpat-setup-$(date +%s)"

GITLAB_PAT=$(docker exec gitlab gitlab-rails runner \
  "token = User.find_by_username('root').personal_access_tokens.create(scopes: [:api], name: '${PAT_NAME}', expires_at: 365.days.from_now); token.set_token('${PAT_TOKEN}'); token.save!; puts token.token" 2>/dev/null)

if [ -z "$GITLAB_PAT" ]; then
  log "✘ Falha ao criar PAT"
  exit 1
fi
log "✔ PAT criado"

# ── 4. Aguardar SonarQube ───────────────────────────────────
log "Aguardando SonarQube..."
until curl -s "${SONAR_URL}/api/system/status" | grep -q '"UP"' 2>/dev/null; do
  sleep 10
done
log "✔ SonarQube pronto"

# ── 5. Alterar senha admin do SonarQube ─────────────────────
log "Alterando senha admin do SonarQube..."
curl -s -u "admin:${SONAR_OLD_PASS}" -X POST \
  "${SONAR_URL}/api/users/change_password" \
  --data-urlencode "login=admin" \
  --data-urlencode "previousPassword=${SONAR_OLD_PASS}" \
  --data-urlencode "password=${SONAR_NEW_PASS}" > /dev/null 2>&1

if curl -s -u "admin:${SONAR_NEW_PASS}" "${SONAR_URL}/api/system/status" | grep -q '"UP"'; then
  SONAR_PASS="${SONAR_NEW_PASS}"
  log "✔ Senha alterada"
else
  SONAR_PASS="${SONAR_OLD_PASS}"
  log "⚠ Mantendo senha atual"
fi

# ── 6. Configurar ALM GitLab no SonarQube ───────────────────
log "Configurando integração GitLab no SonarQube..."
curl -s -u "admin:${SONAR_PASS}" -X POST \
  "${SONAR_URL}/api/alm_settings/create_gitlab" \
  --data-urlencode "key=gitlab-local" \
  --data-urlencode "url=${GITLAB_URL}/api/v4" \
  --data-urlencode "personalAccessToken=${GITLAB_PAT}" > /dev/null 2>&1 || \
curl -s -u "admin:${SONAR_PASS}" -X POST \
  "${SONAR_URL}/api/alm_settings/update_gitlab" \
  --data-urlencode "key=gitlab-local" \
  --data-urlencode "newKey=gitlab-local" \
  --data-urlencode "url=${GITLAB_URL}/api/v4" \
  --data-urlencode "personalAccessToken=${GITLAB_PAT}" > /dev/null 2>&1
log "✔ ALM configurado"

# ── 7. Criar projeto no SonarQube ───────────────────────────
log "Criando projeto no SonarQube..."
curl -s -u "admin:${SONAR_PASS}" -X POST \
  "${SONAR_URL}/api/projects/create" \
  --data-urlencode "project=${PROJECT_KEY}" \
  --data-urlencode "name=${PROJECT_NAME}" > /dev/null 2>&1
log "✔ Projeto '${PROJECT_KEY}' criado"

# ── 8. Gerar token de análise (global) ──────────────────────
log "Gerando SONAR_TOKEN..."
TOKEN_RESP=$(curl -s -u "admin:${SONAR_PASS}" -X POST \
  "${SONAR_URL}/api/user_tokens/generate" \
  --data-urlencode "name=gitlab-ci-global" \
  --data-urlencode "type=GLOBAL_ANALYSIS_TOKEN" 2>/dev/null)

SONAR_TOKEN=$(echo "$TOKEN_RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$SONAR_TOKEN" ]; then
  log "✘ Falha ao gerar token: $TOKEN_RESP"
  exit 1
fi
log "✔ SONAR_TOKEN gerado"

# ── 9. Registrar variáveis CI/CD no GitLab ─────────────────
log "Registrando variáveis CI/CD no GitLab..."
curl -s -H "PRIVATE-TOKEN: ${GITLAB_PAT}" -X POST \
  "${GITLAB_URL}/api/v4/admin/ci/variables" \
  -H "Content-Type: application/json" \
  --data "{\"key\":\"SONAR_TOKEN\",\"value\":\"${SONAR_TOKEN}\",\"masked\":true,\"protected\":false}" > /dev/null 2>&1

curl -s -H "PRIVATE-TOKEN: ${GITLAB_PAT}" -X POST \
  "${GITLAB_URL}/api/v4/admin/ci/variables" \
  -H "Content-Type: application/json" \
  --data "{\"key\":\"SONAR_HOST_URL\",\"value\":\"http://sonarqube:9000\",\"masked\":false,\"protected\":false}" > /dev/null 2>&1

curl -s -H "PRIVATE-TOKEN: ${GITLAB_PAT}" -X POST \
  "${GITLAB_URL}/api/v4/admin/ci/variables" \
  -H "Content-Type: application/json" \
  --data "{\"key\":\"SONAR_ADMIN_PASSWORD\",\"value\":\"${SONAR_PASS}\",\"masked\":true,\"protected\":false}" > /dev/null 2>&1
log "✔ Variáveis CI/CD registradas"

# ── 10. Salvar resultado ─────────────────────────────────────
mkdir -p "$(dirname "$OUTPUT_FILE")"
cat > "$OUTPUT_FILE" <<EOF
GITLAB_ROOT_PASSWORD=${GITLAB_ROOT_PASS}
GITLAB_PAT=${GITLAB_PAT}
SONAR_ADMIN_PASSWORD=${SONAR_PASS}
SONAR_TOKEN=${SONAR_TOKEN}
SONAR_PROJECT_KEY=${PROJECT_KEY}
EOF

log "============================================"
log " ✅ Setup concluído!"
log "============================================"
log " GitLab:    ${GITLAB_URL}  (root / ver setup-result.env)"
log " SonarQube: ${SONAR_URL}  (admin / ${SONAR_PASS})"
log " SONAR_TOKEN e SONAR_HOST_URL configurados no GitLab"
log " Credenciais: docker run --rm -v gitlab-sonar_setup-output:/data alpine cat /data/setup-result.env"
log "============================================"
