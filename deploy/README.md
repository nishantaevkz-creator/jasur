# Serverga joylash (deploy)

O'z kompyuteringizdan **bitta buyruq**:

```bash
git clone https://github.com/nishantaevkz-creator/jasur.git && cd jasur
ssh ubuntu@195.49.212.161 'bash -s' < deploy/setup.sh
```

Skript o'zi bajaradi:
1. Serverda `manage.py` ni topadi (yoki papkani bering: `'bash -s -- /yo/l/loyiha'`)
2. python3-venv, nginx o'rnatadi
3. venv yaratadi, `requirements.txt` + gunicorn o'rnatadi
4. `migrate` va `collectstatic`
5. `jasur.service` (gunicorn, systemd) — server qayta yonsa ham o'zi ishga tushadi
6. nginx: 80-port → gunicorn, `/static/`, `/media/`
7. Tekshiradi va natijani chiqaradi

Foydali buyruqlar (serverda):

```bash
sudo systemctl status jasur          # holati
sudo journalctl -u jasur -n 50       # loglar
sudo systemctl restart jasur         # kod o'zgarganda
```

Agar `400 Bad Request` chiqsa — `settings.py` da `ALLOWED_HOSTS = ['195.49.212.161']` qiling va `sudo systemctl restart jasur`.
