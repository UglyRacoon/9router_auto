#!/usr/bin/env bash
# =============================================================================
#  9router — Global npm install + systemd + Debian 13 "Trixie"
#  npm package : https://www.npmjs.com/package/9router
#  Node.js     : 24.x LTS (Active LTS "Krypton")
#  Порт        : 20128
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  ЦВЕТА
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()    { echo -e "\n${CYAN}${BOLD}[STEP]${NC} $*"; }
ok()      { echo -e "${GREEN}[  OK  ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[ WARN ]${NC} $*"; }
fail()    { echo -e "${RED}[ FAIL ]${NC} $*"; exit 1; }
info()    { echo -e "         $*"; }
divider() { echo -e "${CYAN}$(printf '─%.0s' {1..72})${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
#  КОНФИГУРАЦИЯ
# ─────────────────────────────────────────────────────────────────────────────
PORT="${PORT:-20128}"
NODE_MAJOR="24"
SERVICE_NAME="9router"
APP_USER="ninerouter"
DATA_DIR="/var/lib/9router"
LOG_DIR="/var/log/9router"
ENV_FILE="/etc/9router/env"

# ─────────────────────────────────────────────────────────────────────────────
#  ШАПКА
# ─────────────────────────────────────────────────────────────────────────────
divider
echo -e "${BOLD}   9router — npm global install + systemd  |  Debian 13 \"Trixie\"${NC}"
echo -e "${BOLD}   Node.js target : ${NODE_MAJOR}.x LTS \"Krypton\" (via NodeSource)${NC}"
divider

# ─────────────────────────────────────────────────────────────────────────────
#  ROOT-ПРОВЕРКА
# ─────────────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && fail "Запустите скрипт от root: sudo bash $0"
ok "Запуск от root"

# ─────────────────────────────────────────────────────────────────────────────
#  ЗАПРОС ПАРОЛЯ (сразу после проверки root, до всех шагов)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Настройка пароля администратора 9router${NC}"
echo -e "  ${YELLOW}Требования:${NC} минимум 8 символов, используйте буквы + цифры"
echo ""

USER_PASSWORD=""
while true; do
  # Читаем без echo (скрытый ввод)
  read -r -s -p "  Введите пароль для входа в 9router: " USER_PASSWORD
  echo ""

  # Проверка длины
  if [[ ${#USER_PASSWORD} -lt 8 ]]; then
    echo -e "  ${RED}Пароль слишком короткий (минимум 8 символов). Повторите.${NC}"
    echo ""
    continue
  fi

  # Подтверждение пароля
  read -r -s -p "  Подтвердите пароль                 : " USER_PASSWORD_CONFIRM
  echo ""

  if [[ "${USER_PASSWORD}" != "${USER_PASSWORD_CONFIRM}" ]]; then
    echo -e "  ${RED}Пароли не совпадают. Повторите.${NC}"
    echo ""
    continue
  fi

  # Всё ок
  ok "Пароль принят"
  break
done

echo ""

# ─────────────────────────────────────────────────────────────────────────────
#  ОПРЕДЕЛЕНИЕ ОС И IP
# ─────────────────────────────────────────────────────────────────────────────
DISTRO_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"' || echo "unknown")
DISTRO_VER=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"' || echo "0")
DISTRO_CODENAME=$(grep -oP '(?<=^VERSION_CODENAME=).+' /etc/os-release | tr -d '"' || echo "unknown")

info "Дистрибутив   : ${DISTRO_ID} ${DISTRO_VER} (${DISTRO_CODENAME})"
[[ "${DISTRO_ID}" != "debian" ]] && \
  warn "Ожидается Debian, обнаружен '${DISTRO_ID}' — продолжаем, но без гарантий"

EXTERNAL_IP=$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null \
           || curl -s --max-time 6 https://ifconfig.me 2>/dev/null \
           || hostname -I | awk '{print $1}')
INTERNAL_IP=$(hostname -I | awk '{print $1}')

info "Внутренний IP : ${INTERNAL_IP}"
info "Внешний IP    : ${EXTERNAL_IP}"
info "Порт сервиса  : ${PORT}"

# ─────────────────────────────────────────────────────────────────────────────
#  ШАГ 1 — БАЗОВЫЕ СИСТЕМНЫЕ ПАКЕТЫ
# ─────────────────────────────────────────────────────────────────────────────
step "1/8 · Системные зависимости (Debian 13 Trixie)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

PKGS=(
  curl
  ca-certificates
  gnupg
  apt-transport-https
  lsb-release
  net-tools
  lsof
  openssl
  jq
  iptables
  iptables-persistent
  netfilter-persistent
)

TO_INSTALL=()
for pkg in "${PKGS[@]}"; do
  dpkg -s "$pkg" &>/dev/null || TO_INSTALL+=("$pkg")
done

if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
  info "Устанавливаем: ${TO_INSTALL[*]}"
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" \
    | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" \
    | debconf-set-selections
  apt-get install -y -qq "${TO_INSTALL[@]}"
  ok "Установлено: ${TO_INSTALL[*]}"
else
  ok "Все системные пакеты уже присутствуют"
fi

# Проверяем наличие UFW (опционально)
UFW_AVAILABLE=0
if command -v ufw &>/dev/null; then
  UFW_AVAILABLE=1
  ok "UFW обнаружен — будет использован вместо iptables"
else
  info "UFW не найден — будем использовать iptables напрямую"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  ШАГ 2 — NODE.JS 24 LTS (DEB822-метод, без pipe | bash)
# ─────────────────────────────────────────────────────────────────────────────
step "2/8 · Node.js ${NODE_MAJOR}.x LTS (NodeSource → Debian Trixie)"

NEED_NODE=1
if command -v node &>/dev/null; then
  CUR=$(node --version | grep -oP '(?<=v)\d+' | head -1)
  if [[ "${CUR}" -ge "${NODE_MAJOR}" ]]; then
    ok "Node.js $(node --version) уже установлен — пропускаем"
    NEED_NODE=0
  else
    warn "Найден Node.js v${CUR} < ${NODE_MAJOR} — обновляем"
    apt-get remove -y -qq nodejs nodejs-legacy 2>/dev/null || true
  fi
fi

if [[ $NEED_NODE -eq 1 ]]; then
  info "Добавляем GPG-ключ NodeSource..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  chmod 644 /etc/apt/keyrings/nodesource.gpg
  ok "GPG-ключ → /etc/apt/keyrings/nodesource.gpg"

  info "Добавляем репозиторий NodeSource (Node.js ${NODE_MAJOR}.x, nodistro)..."
  cat > /etc/apt/sources.list.d/nodesource.list <<EOF
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main
EOF
  chmod 644 /etc/apt/sources.list.d/nodesource.list
  ok "Репозиторий → /etc/apt/sources.list.d/nodesource.list"

  info "apt-get update + установка nodejs..."
  apt-get update -qq
  apt-get install -y -qq nodejs
  ok "Node.js $(node --version) установлен"
fi

info "node : $(node --version)"
info "npm  : $(npm --version)"

# ─────────────────────────────────────────────────────────────────────────────
#  ШАГ 3 — ГЛОБАЛЬНАЯ УСТАНОВКА 9router
# ─────────────────────────────────────────────────────────────────────────────
step "3/8 · npm install -g 9router"

if command -v 9router &>/dev/null; then
  OLD_VER=$(9router --version 2>/dev/null || echo "неизвестна")
  warn "9router уже установлен (версия: ${OLD_VER}) — обновляем..."
  npm install -g 9router 2>&1 | tail -5
  NEW_VER=$(9router --version 2>/dev/null || echo "неизвестна")
  ok "9router обновлён: ${OLD_VER} → ${NEW_VER}"
else
  info "Устанавливаем 9router глобально..."
  npm install -g 9router 2>&1 | tail -8
  ok "9router $(9router --version 2>/dev/null || echo '') установлен"
fi

# Определяем путь к бинарнику
NINE_BIN=$(which 9router || true)
if [[ -z "${NINE_BIN}" ]]; then
  NINE_BIN="$(npm bin -g)/9router"
fi
[[ ! -x "${NINE_BIN}" ]] && \
  fail "Бинарник 9router не найден после установки. Проверьте: npm install -g 9router"

info "Бинарник : ${NINE_BIN}"
info "Версия   : $(9router --version 2>/dev/null || echo 'н/д')"

# ─────────────────────────────────────────────────────────────────────────────
#  ШАГ 4 — СИСТЕМНЫЙ ПОЛЬЗОВАТЕЛЬ, ДИРЕКТОРИИ, ENV-ФАЙЛ
# ─────────────────────────────────────────────────────────────────────────────
step "4/8 · Пользователь, директории, конфигурация"

# Пользователь
if id "${APP_USER}" &>/dev/null; then
  ok "Пользователь ${APP_USER} уже существует"
else
  useradd --system \
          --no-create-home \
          --shell /usr/sbin/nologin \
          --comment "9router service account" \
          "${APP_USER}"
  ok "Системный пользователь ${APP_USER} создан"
fi

# Директории
mkdir -p "${DATA_DIR}" "${LOG_DIR}" "$(dirname "${ENV_FILE}")"
chown "${APP_USER}:${APP_USER}" "${DATA_DIR}" "${LOG_DIR}"
chmod 750 "${DATA_DIR}" "${LOG_DIR}"

ok "Директории созданы"
info "data : ${DATA_DIR}"
info "logs : ${LOG_DIR}"

# JWT_SECRET — генерируем всегда новый если не задан снаружи
JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"

# ENV-файл — перезаписываем чтобы пароль точно применился
# (если файл уже существовал — бэкапим)
if [[ -f "${ENV_FILE}" ]]; then
  cp "${ENV_FILE}" "${ENV_FILE}.bak.$(date +%s)"
  warn "Старый env-файл сохранён как ${ENV_FILE}.bak.*"
fi

cat > "${ENV_FILE}" <<ENVEOF
# ── 9router environment ──────────────────────────────────────────────────────
# Создано  : $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Debian   : ${DISTRO_ID} ${DISTRO_VER} (${DISTRO_CODENAME})
# Node.js  : $(node --version)

# Сетевые настройки
PORT=${PORT}
HOSTNAME=0.0.0.0

# Директория данных
DATA_DIR=${DATA_DIR}

# Режим работы
NODE_ENV=production

# Пароль администратора (задан при установке)
INITIAL_PASSWORD=${USER_PASSWORD}

# JWT секрет (не менять после первого запуска — инвалидирует все сессии)
JWT_SECRET=${JWT_SECRET}

# URL для редиректов и внешних ссылок
BASE_URL=http://${EXTERNAL_IP}:${PORT}
NEXT_PUBLIC_BASE_URL=http://${EXTERNAL_IP}:${PORT}

# Отключить автооткрытие браузера при старте
BROWSER=none
ENVEOF

# Только root читает файл с секретами
chmod 640 "${ENV_FILE}"
chown root:root "${ENV_FILE}"
ok "Env-файл создан: ${ENV_FILE} (права 640, владелец root)"

# ─────────────────────────────────────────────────────────────────────────────
#  ШАГ 5 — SYSTEMD UNIT
# ─────────────────────────────────────────────────────────────────────────────
step "5/8 · Systemd unit /etc/systemd/system/${SERVICE_NAME}.service"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=9router — AI Proxy Gateway (npm global)
Documentation=https://github.com/decolua/9router
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}

# Переменные окружения из защищённого файла
EnvironmentFile=${ENV_FILE}

# Явный PATH — Debian иначе резолвит npm-глобальные бинарники
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Запуск
ExecStart=${NINE_BIN} --port ${PORT} --no-browser --skip-update

# Перезапуск при сбое
Restart=on-failure
RestartSec=10
StartLimitBurst=5
StartLimitIntervalSec=120

# Логирование в файл (journald в Debian 13 — volatile по умолчанию)
StandardOutput=append:${LOG_DIR}/9router.log
StandardError=append:${LOG_DIR}/9router-error.log
SyslogIdentifier=9router

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${DATA_DIR} ${LOG_DIR}

# Ресурсы
LimitNOFILE=65536
TimeoutStartSec=90
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
ok "Systemd unit создан и перезагружен"

# ─────────────────────────────────────────────────────────────────────────────
#  ШАГ 6 — FIREWALL
#  UFW если доступен, иначе iptables напрямую
# ─────────────────────────────────────────────────────────────────────────────
step "6/8 · Firewall (порт ${PORT}/tcp)"

if [[ $UFW_AVAILABLE -eq 1 ]]; then
  # ── Вариант A: UFW ──────────────────────────────────────────────────────
  ufw allow ssh comment "SSH" 2>/dev/null || true

  if ! ufw status | grep -q "Status: active"; then
    ufw --force enable 2>&1 | tail -1
    ok "UFW активирован"
  else
    ok "UFW уже активен"
  fi

  ufw allow "${PORT}/tcp" comment "9router" 2>/dev/null || true
  ufw reload 2>/dev/null || true
  ok "UFW: порт ${PORT}/tcp открыт"

else
  # ── Вариант B: iptables напрямую ────────────────────────────────────────
  info "Используем iptables (UFW недоступен)"

  if ! iptables -C INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null; then
    iptables -A INPUT -p tcp --dport "${PORT}" -j ACCEPT
    ok "iptables: правило для порта ${PORT}/tcp добавлено"
  else
    ok "iptables: правило для порта ${PORT}/tcp уже существует"
  fi

  if ! iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; then
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    ok "iptables: правило SSH (22/tcp) добавлено"
  fi

  # Сохраняем правила
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save 2>&1 | tail -3
    ok "iptables: правила сохранены через netfilter-persistent"
  else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ok "iptables: правила сохранены → /etc/iptables/rules.v4"
  fi
fi

# Показываем правила для нашего порта
info "Правила для порта ${PORT}:"
iptables -L INPUT -n --line-numbers 2>/dev/null \
  | grep -E "(${PORT})" \
  | while read -r line; do info "  ${line}"; done || true

# ─────────────────────────────────────────────────────────────────────────────
#  ШАГ 7 — ЗАПУСК СЕРВИСА
# ─────────────────────────────────────────────────────────────────────────────
step "7/8 · Enable + Start ${SERVICE_NAME}"

# Если сервис уже работал — рестартуем чтобы применился новый пароль из env
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
  warn "Сервис уже запущен — выполняем restart для применения нового пароля..."
  systemctl restart "${SERVICE_NAME}"
else
  systemctl enable "${SERVICE_NAME}" 2>&1
  systemctl start  "${SERVICE_NAME}"
fi

# Ждём active-статуса
echo -n "     Ожидание active-статуса"
WAITED=0
while [[ $WAITED -lt 45 ]]; do
  sleep 2; WAITED=$((WAITED+2))
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo ""; ok "Systemd: сервис active (за ${WAITED}с)"; break
  fi
  echo -n "."
  if [[ $WAITED -ge 45 ]]; then
    echo ""
    warn "Сервис не стал active за 45с — вывод логов:"
    journalctl -u "${SERVICE_NAME}" -n 40 --no-pager 2>/dev/null || \
      tail -40 "${LOG_DIR}/9router-error.log" 2>/dev/null || true
    fail "Сервис не запустился"
  fi
done

# Ждём HTTP-готовности
echo -n "     Ожидание HTTP на порту ${PORT}"
WAITED=0; HTTP_UP=0
while [[ $WAITED -lt 90 ]]; do
  sleep 3; WAITED=$((WAITED+3))
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 4 "http://127.0.0.1:${PORT}/" 2>/dev/null || echo "000")
  if [[ "${CODE}" =~ ^(200|301|302|307|308|401|403)$ ]]; then
    HTTP_UP=1; echo ""; ok "HTTP готов (код ${CODE}, за ${WAITED}с)"; break
  fi
  echo -n "."
done
echo ""

if [[ $HTTP_UP -eq 0 ]]; then
  warn "HTTP не ответил за 90с — последние строки лога:"
  tail -20 "${LOG_DIR}/9router.log" 2>/dev/null \
    | while read -r line; do info "  ${line}"; done || true
fi

# ─────────────────────────────────────────────────────────────────────────────
#  ШАГ 8 — КОМПЛЕКСНЫЕ ПРОВЕРКИ
# ─────────────────────────────────────────────────────────────────────────────
step "8/8 · Комплексные проверки"

PASS=0; FAIL=0

chk() {
  local DESC="$1"; local CMD="$2"; local EXPECT="${3:-ANY}"
  local OUT
  OUT=$(eval "${CMD}" 2>/dev/null || echo "__ERROR__")
  if [[ "${EXPECT}" == "ANY" ]]; then
    if [[ "${OUT}" != "__ERROR__" && -n "${OUT}" ]]; then
      ok "✔  ${DESC}: ${OUT:0:60}"; PASS=$((PASS+1))
    else
      warn "✘  ${DESC}: нет ответа / ошибка"; FAIL=$((FAIL+1))
    fi
  else
    if echo "${OUT}" | grep -q "${EXPECT}"; then
      ok "✔  ${DESC}"; PASS=$((PASS+1))
    else
      warn "✘  ${DESC} → (ожидал '${EXPECT}', получил '${OUT:0:80}')"; FAIL=$((FAIL+1))
    fi
  fi
}

http_code() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$1" 2>/dev/null || echo "000"
}

divider
echo -e "${BOLD}   РЕЗУЛЬТАТЫ ПРОВЕРОК${NC}"
divider

# ── systemd ───────────────────────────────────────────────────────────────────
chk "systemd: сервис active"  "systemctl is-active ${SERVICE_NAME}"  "active"
chk "systemd: сервис enabled" "systemctl is-enabled ${SERVICE_NAME}" "enabled"

# ── Node.js версия ────────────────────────────────────────────────────────────
chk "Node.js >= ${NODE_MAJOR}" \
  "node --version | grep -oP '(?<=v)\d+' | awk -v m=${NODE_MAJOR} '\$1>=m{print \"ok\"}'" \
  "ok"

# ── порт слушается ────────────────────────────────────────────────────────────
chk "Порт ${PORT} прослушивается (ss)" \
  "ss -tlnp | grep ':${PORT}'" "${PORT}"

# ── процесс по порту (ИСПРАВЛЕННАЯ проверка) ──────────────────────────────────
# Ищем PID который держит наш порт, затем смотрим имя процесса
PID_ON_PORT=$(ss -tlnp "sport = :${PORT}" 2>/dev/null \
  | grep -oP 'pid=\K\d+' | head -1 || echo "")
if [[ -n "${PID_ON_PORT}" ]]; then
  PROC_NAME=$(ps -p "${PID_ON_PORT}" -o comm= 2>/dev/null || echo "неизвестно")
  PROC_CMD=$(ps -p "${PID_ON_PORT}" -o args= 2>/dev/null | cut -c1-50 || echo "")
  ok "✔  Процесс на порту ${PORT}: ${PROC_NAME} (PID ${PID_ON_PORT}) ${PROC_CMD}"
  PASS=$((PASS+1))
else
  warn "✘  Процесс на порту ${PORT} не найден"
  FAIL=$((FAIL+1))
fi

# ── HTTP localhost ─────────────────────────────────────────────────────────────
LOC_CODE=$(http_code "http://127.0.0.1:${PORT}/")
if [[ "${LOC_CODE}" =~ ^(200|301|302|307|308|401|403)$ ]]; then
  ok "✔  HTTP localhost:${PORT} → код ${LOC_CODE}"; PASS=$((PASS+1))
else
  warn "✘  HTTP localhost:${PORT} → код ${LOC_CODE}"; FAIL=$((FAIL+1))
fi

# ── API /v1/models ─────────────────────────────────────────────────────────────
API_CODE=$(http_code "http://127.0.0.1:${PORT}/v1/models")
if [[ "${API_CODE}" =~ ^(200|401|403)$ ]]; then
  ok "✔  API /v1/models → код ${API_CODE}"; PASS=$((PASS+1))
else
  warn "✘  API /v1/models → код ${API_CODE}"; FAIL=$((FAIL+1))
fi

# ── HTTP внутренний IP ─────────────────────────────────────────────────────────
INT_CODE=$(http_code "http://${INTERNAL_IP}:${PORT}/")
if [[ "${INT_CODE}" =~ ^(200|301|302|307|308|401|403)$ ]]; then
  ok "✔  HTTP внутренний IP ${INTERNAL_IP}:${PORT} → код ${INT_CODE}"; PASS=$((PASS+1))
else
  warn "✘  HTTP внутренний IP ${INTERNAL_IP}:${PORT} → код ${INT_CODE}"; FAIL=$((FAIL+1))
fi

# ── HTTP внешний IP ────────────────────────────────────────────────────────────
echo ""
info "Проверка ВНЕШНЕЙ доступности (http://${EXTERNAL_IP}:${PORT})..."
EXT_CODE=$(http_code "http://${EXTERNAL_IP}:${PORT}/")
if [[ "${EXT_CODE}" =~ ^(200|301|302|307|308|401|403)$ ]]; then
  ok "✔  ВНЕШНИЙ доступ: http://${EXTERNAL_IP}:${PORT} → код ${EXT_CODE}"; PASS=$((PASS+1))
elif [[ "${EXT_CODE}" == "000" ]]; then
  warn "✘  Нет ответа от ${EXTERNAL_IP}:${PORT}"
  warn "   Вероятные причины:"
  info "   • Порт ${PORT} закрыт в Security Group / ACL хостинга"
  info "   • NAT на стороне провайдера"
  info "   → Откройте порт ${PORT} TCP в панели управления хостингом"
  FAIL=$((FAIL+1))
else
  ok "✔  Внешний IP отвечает (HTTP ${EXT_CODE})"; PASS=$((PASS+1))
fi

# ── файлы и права ──────────────────────────────────────────────────────────────
chk "ENV-файл существует (права 640)" \
  "stat -c '%a' ${ENV_FILE}" "640"

chk "DATA_DIR принадлежит ${APP_USER}" \
  "stat -c '%U' ${DATA_DIR}" "${APP_USER}"

chk "LOG-файл создан" \
  "test -f ${LOG_DIR}/9router.log && echo ok" "ok"

# ── firewall ───────────────────────────────────────────────────────────────────
chk "Firewall: порт ${PORT} открыт (iptables)" \
  "iptables -L INPUT -n | grep '${PORT}'" "${PORT}"

# ── INITIAL_PASSWORD применён в env ───────────────────────────────────────────
chk "INITIAL_PASSWORD задан в env-файле" \
  "grep -c 'INITIAL_PASSWORD' ${ENV_FILE}" "1"

# ─────────────────────────────────────────────────────────────────────────────
#  ФИНАЛЬНЫЙ ОТЧЁТ
# ─────────────────────────────────────────────────────────────────────────────
echo ""
divider
echo -e "${BOLD}   ИТОГОВЫЙ ОТЧЁТ${NC}"
divider
echo ""
echo -e "  ${GREEN}${BOLD}✔ Пройдено проверок : ${PASS}${NC}"
[[ $FAIL -gt 0 ]] && echo -e "  ${RED}${BOLD}✘ Провалено         : ${FAIL}${NC}"
echo ""

echo -e "${BOLD}  ┌─ ДОСТУП ──────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}  │${NC}  Локально   : http://localhost:${PORT}                        ${BOLD}│${NC}"
echo -e "${BOLD}  │${NC}  Сеть       : http://${INTERNAL_IP}:${PORT}                   ${BOLD}│${NC}"
echo -e "${BOLD}  │${NC}  Интернет   : http://${EXTERNAL_IP}:${PORT}                   ${BOLD}│${NC}"
echo -e "${BOLD}  │${NC}  API Base   : http://${EXTERNAL_IP}:${PORT}/v1                ${BOLD}│${NC}"
echo -e "${BOLD}  │${NC}  Модели     : http://${EXTERNAL_IP}:${PORT}/v1/models         ${BOLD}│${NC}"
echo -e "${BOLD}  └───────────────────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "${BOLD}  ┌─ УЧЁТНЫЕ ДАННЫЕ ───────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}  │${NC}  Логин      : admin                                          ${BOLD}│${NC}"
echo -e "${BOLD}  │${NC}  Пароль     : ${GREEN}${BOLD}${USER_PASSWORD}${NC}$(printf '%*s' $((44 - ${#USER_PASSWORD})) '')${BOLD}│${NC}"
echo -e "${BOLD}  │${NC}                                                              ${BOLD}│${NC}"
echo -e "${BOLD}  │${NC}  ${YELLOW}Пароль сохранён в: ${ENV_FILE}${NC}$(printf '%*s' $((16 - ${#ENV_FILE})) '')${BOLD}│${NC}"
echo -e "${BOLD}  └───────────────────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "${BOLD}  УПРАВЛЕНИЕ${NC}"
echo -e "  systemctl status  ${SERVICE_NAME}"
echo -e "  systemctl restart ${SERVICE_NAME}"
echo -e "  systemctl stop    ${SERVICE_NAME}"
echo -e "  journalctl -u ${SERVICE_NAME} -f"
echo -e "  tail -f ${LOG_DIR}/9router.log"
echo ""

echo -e "${BOLD}  ФАЙЛЫ${NC}"
echo -e "  Бинарник : ${NINE_BIN}"
echo -e "  Данные   : ${DATA_DIR}"
echo -e "  Логи     : ${LOG_DIR}/"
echo -e "  ENV      : ${ENV_FILE}"
echo -e "  Systemd  : /etc/systemd/system/${SERVICE_NAME}.service"
echo ""

echo -e "${BOLD}  СМЕНА ПАРОЛЯ В БУДУЩЕМ${NC}"
echo -e "  nano ${ENV_FILE}               # изменить INITIAL_PASSWORD=..."
echo -e "  systemctl restart ${SERVICE_NAME}    # применить"
echo ""

echo -e "${BOLD}  ОБНОВЛЕНИЕ 9router${NC}"
echo -e "  npm install -g 9router && systemctl restart ${SERVICE_NAME}"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}  ⚠  Есть проблемы. Диагностика:${NC}"
  echo -e "  journalctl -u ${SERVICE_NAME} -n 60 --no-pager"
  echo -e "  cat ${LOG_DIR}/9router-error.log"
else
  echo -e "${GREEN}${BOLD}  ✅ Установка завершена! 9router работает на Debian 13 Trixie + Node.js $(node --version)${NC}"
fi
divider
