#!/usr/bin/env bash
# Django loyihasini Ubuntu serverda gunicorn + nginx bilan ishga tushiradi.
# Ishlatish (o'z kompyuteringizdan):
#   ssh ubuntu@195.49.212.161 'bash -s' < deploy/setup.sh
# Yoki loyiha papkasini aniq ko'rsatib:
#   ssh ubuntu@195.49.212.161 'bash -s -- /home/ubuntu/myproject' < deploy/setup.sh
# Qayta ishga tushirish xavfsiz (idempotent).
set -euo pipefail

say()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[X] %s\033[0m\n' "$*"; exit 1; }

APP_NAME="${APP_NAME:-jasur}"
RUN_USER="$(id -un)"

# 1. Loyiha papkasini topish
if [[ $# -ge 1 && -n "$1" ]]; then
  PROJECT_DIR="$(realpath "$1")"
else
  say "manage.py qidirilmoqda..."
  MANAGE="$(sudo find / -name manage.py \
    -not -path '*/venv/*' -not -path '*/.venv/*' -not -path '*/site-packages/*' \
    -not -path '/proc/*' -not -path '/snap/*' 2>/dev/null | head -1 || true)"
  [[ -n "$MANAGE" ]] || die "manage.py topilmadi. Papkani argument sifatida bering."
  PROJECT_DIR="$(dirname "$MANAGE")"
fi
[[ -f "$PROJECT_DIR/manage.py" ]] || die "$PROJECT_DIR ichida manage.py yo'q."
say "Loyiha: $PROJECT_DIR"
cd "$PROJECT_DIR"

# 2. Settings va WSGI modulini aniqlash
SETTINGS_MODULE="$(grep -oP "DJANGO_SETTINGS_MODULE['\"],\s*['\"]\K[^'\"]+" manage.py | head -1 || true)"
[[ -n "$SETTINGS_MODULE" ]] || die "manage.py dan DJANGO_SETTINGS_MODULE aniqlanmadi."
PKG="${SETTINGS_MODULE%%.*}"
WSGI_MODULE="$PKG.wsgi:application"
[[ -f "$PKG/wsgi.py" ]] || warn "$PKG/wsgi.py topilmadi, WSGI: $WSGI_MODULE deb olinadi."
say "Settings: $SETTINGS_MODULE | WSGI: $WSGI_MODULE"

# 3. Tizim paketlari
say "Paketlar o'rnatilmoqda (python3-venv, nginx)..."
sudo apt-get update -y -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv python3-pip python3-dev build-essential nginx libpq-dev

# 4. Virtual muhit va kutubxonalar
VENV="$PROJECT_DIR/venv"
for cand in "$PROJECT_DIR/venv" "$PROJECT_DIR/.venv" "$PROJECT_DIR/env"; do
  [[ -x "$cand/bin/python" ]] && { VENV="$cand"; break; }
done
[[ -x "$VENV/bin/python" ]] || { say "venv yaratilmoqda: $VENV"; python3 -m venv "$VENV"; }
PY="$VENV/bin/python"
"$PY" -m pip install -q --upgrade pip wheel
REQ=""
for cand in requirements.txt requirements/prod.txt requirements/production.txt ../requirements.txt; do
  [[ -f "$cand" ]] && { REQ="$cand"; break; }
done
if [[ -n "$REQ" ]]; then
  say "Kutubxonalar: $REQ"
  "$PY" -m pip install -q -r "$REQ"
else
  warn "requirements.txt topilmadi — faqat Django va gunicorn o'rnatiladi."
  "$PY" -m pip install -q django
fi
"$PY" -m pip install -q gunicorn

# 5. Migratsiya va statik fayllar
say "Migratsiyalar..."
"$PY" manage.py migrate --noinput
STATIC_ROOT="$("$PY" manage.py shell -c "from django.conf import settings; print(settings.STATIC_ROOT or '')" 2>/dev/null | tail -1 || true)"
MEDIA_ROOT="$("$PY" manage.py shell -c "from django.conf import settings; print(settings.MEDIA_ROOT or '')" 2>/dev/null | tail -1 || true)"
if [[ -n "$STATIC_ROOT" ]]; then
  say "collectstatic -> $STATIC_ROOT"
  "$PY" manage.py collectstatic --noinput >/dev/null
else
  warn "settings.py da STATIC_ROOT yo'q — CSS/JS nginx orqali berilmaydi. Qo'shing: STATIC_ROOT = BASE_DIR / 'staticfiles'"
fi

# nginx (www-data) home papkadagi fayllarni o'qiy olishi uchun
allow_traverse() { local d="$1"; while [[ "$d" != "/" && -n "$d" ]]; do sudo chmod o+x "$d" 2>/dev/null || true; d="$(dirname "$d")"; done; }
[[ -n "$STATIC_ROOT" ]] && { allow_traverse "$STATIC_ROOT"; sudo chmod -R o+rX "$STATIC_ROOT"; }
[[ -n "$MEDIA_ROOT" && -d "$MEDIA_ROOT" ]] && { allow_traverse "$MEDIA_ROOT"; sudo chmod -R o+rX "$MEDIA_ROOT"; }

# 6. systemd: gunicorn xizmati
ENV_LINE=""
[[ -f "$PROJECT_DIR/.env" ]] && ENV_LINE="EnvironmentFile=$PROJECT_DIR/.env"
say "systemd xizmati: $APP_NAME.service"
sudo tee "/etc/systemd/system/$APP_NAME.service" >/dev/null <<EOF
[Unit]
Description=$APP_NAME gunicorn (Django)
After=network.target

[Service]
User=$RUN_USER
Group=www-data
WorkingDirectory=$PROJECT_DIR
Environment=DJANGO_SETTINGS_MODULE=$SETTINGS_MODULE
$ENV_LINE
RuntimeDirectory=$APP_NAME
RuntimeDirectoryMode=0775
ExecStart=$VENV/bin/gunicorn --workers 3 --timeout 60 --bind unix:/run/$APP_NAME/gunicorn.sock $WSGI_MODULE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now "$APP_NAME.service"
sudo systemctl restart "$APP_NAME.service"

# 7. nginx
say "nginx sozlanmoqda..."
STATIC_BLOCK=""; MEDIA_BLOCK=""
[[ -n "$STATIC_ROOT" ]] && STATIC_BLOCK="    location /static/ { alias ${STATIC_ROOT%/}/; expires 7d; }"
[[ -n "$MEDIA_ROOT"  ]] && MEDIA_BLOCK="    location /media/  { alias ${MEDIA_ROOT%/}/; }"
sudo tee "/etc/nginx/sites-available/$APP_NAME" >/dev/null <<EOF
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 50M;

$STATIC_BLOCK
$MEDIA_BLOCK

    location / {
        proxy_pass http://unix:/run/$APP_NAME/gunicorn.sock;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
sudo ln -sf "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-enabled/$APP_NAME"
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx

# 8. Firewall
if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then
  sudo ufw allow 'Nginx Full' >/dev/null; sudo ufw allow OpenSSH >/dev/null
fi

# 9. Tekshiruv
sleep 2
IP="$(hostname -I | awk '{print $1}')"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $IP" http://127.0.0.1/ || true)"
say "Tayyor! HTTP javob kodi: $CODE"
case "$CODE" in
  200|301|302|404) echo "Sayt ishlayapti: http://$IP/" ;;
  400) warn "400 — settings.py da ALLOWED_HOSTS ga '$IP' (yoki domeningizni) qo'shing, so'ng: sudo systemctl restart $APP_NAME" ;;
  502) warn "502 — gunicorn ishlamayapti. Log: sudo journalctl -u $APP_NAME -n 50 --no-pager" ;;
  *)   warn "Kutilmagan javob. Log: sudo journalctl -u $APP_NAME -n 50 --no-pager" ;;
esac
grep -qE "^\s*DEBUG\s*=\s*True" "$PKG/settings.py" 2>/dev/null && warn "settings.py da DEBUG = True — productionda False qiling."
exit 0
