# Развёртывание сервера (VPS)

Нужно: VPS (Ubuntu 24.04 LTS, 2 vCPU / 4 ГБ RAM, системный диск 40 ГБ + отдельный том под данные, на старт 250 ГБ),
домен, SSH-ключ на твоём компьютере.

## 1. Домен
Создай у регистратора A-запись `api.твойдомен.com` → IP сервера. Дождись, пока она заработает (`ping api.твойдомен.com`).

## 2. Первичная защита сервера (под root)
```bash
adduser deploy && usermod -aG sudo deploy
mkdir -p /home/deploy/.ssh && cp ~/.ssh/authorized_keys /home/deploy/.ssh/ && chown -R deploy:deploy /home/deploy/.ssh
# отключить вход по паролю и под root:
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/; s/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh
apt update && apt -y install ufw fail2ban unattended-upgrades
ufw default deny incoming && ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw --force enable
```
Проверь вход `ssh deploy@сервер` в НОВОМ окне до того, как закроешь старое.

## 3. Docker
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker deploy   # перезайди по SSH
```

## 4. Диск под данные
Смонтируй отдельный том в `/srv/appdata` (расширяемый у провайдера), затем:
```bash
sudo mkdir -p /srv/appdata /srv/pgdata
sudo chown -R 10001:10001 /srv/appdata
```

## 5. Код и настройки
```bash
sudo mkdir -p /opt/app && sudo chown deploy:deploy /opt/app
git clone https://github.com/root0217/iosApp.git /opt/app && cd /opt/app
cp env.example .env && nano .env      # заполни DOMAIN, пароли, ключи (команды для генерации в самом файле)
chmod 600 .env
docker compose up -d --build
docker compose logs -f api            # должно быть «сервер запущен»
```
Если репозиторий приватный, клонируй по SSH-ключу (deploy key) или токену.

## 6. Аккаунт-владелец
Регистрация в Chapa открытая — любой может создать обычный аккаунт через `/auth/register/start` +
`/auth/register/confirm` прямо из приложения. Аккаунт с правами администратора (`is_admin=True`) так
создать нельзя: для него отдельная команда, которая пишет в базу напрямую, в обход API:
```bash
docker compose exec api python -m app.manage create-owner
```
Спросит пароль дважды и покажет recovery-код **один раз** — сразу его сохрани, второй раз он не
показывается. Username фиксированный — `chapa`.
Проверка входа:
```bash
curl -X POST https://api.твойдомен.com/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"chapa","password":"…","device_name":"test"}'
```

## 7. Бэкапы (restic)
Бэкап должен лежать в ДРУГОМ месте: второй сервер или storage box по SFTP, домашний ПК/NAS.
```bash
sudo apt -y install restic
openssl rand -hex 32 | sudo tee /etc/app-backup.pass >/dev/null && sudo chmod 600 /etc/app-backup.pass
# ВАЖНО: сохрани этот пароль отдельно (менеджер паролей). Без него бэкап не открыть.
sudo tee /etc/app-backup.env >/dev/null <<'X'
export RESTIC_REPOSITORY=sftp:user@backup-host:/backups/app
export RESTIC_PASSWORD_FILE=/etc/app-backup.pass
X
sudo chmod 600 /etc/app-backup.env
source /etc/app-backup.env && restic init
```
Расписание (cron, каждую ночь в 03:30):
```bash
( crontab -l 2>/dev/null; echo '30 3 * * * /opt/app/backup/backup.sh >> /var/log/app-backup.log 2>&1' ) | crontab -
```
Раз в месяц проверяй восстановление: `restic restore latest --target /tmp/restore-test`.

## 8. Обновление
```bash
cd /opt/app && git pull && docker compose up -d --build
```
Данные (диск `/srv/appdata`, база `/srv/pgdata`) при пересборке не затрагиваются.
