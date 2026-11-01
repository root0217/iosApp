#!/usr/bin/env bash
# Ночной бэкап: дамп PostgreSQL + файлы -> restic (шифрованный, инкрементальный) в ДРУГОЕ место.
# Запуск: из cron/systemd-timer от пользователя, который может выполнять docker compose.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/app}"          # где лежит docker-compose.yml и .env
DUMP_DIR="${DUMP_DIR:-/var/backups/app}"
# RESTIC_REPOSITORY и RESTIC_PASSWORD_FILE берём из отдельного файла (не из репозитория!)
source "${RESTIC_ENV:-/etc/app-backup.env}"

cd "$APP_DIR"
set -a; source .env; set +a

mkdir -p "$DUMP_DIR"
docker compose exec -T db pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" > "$DUMP_DIR/db-$(date +%F).dump"

# каталог objects (файлы пользователя) + свежие дампы БД. staging (недозагруженное) не нужен.
restic backup --tag nightly "$DUMP_DIR" "${DATA_DIR}/objects"

# хранение: 7 дневных, 4 недельных, 6 месячных
restic forget --tag nightly --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# локальные дампы старше 3 дней не нужны (они уже в restic)
find "$DUMP_DIR" -name 'db-*.dump' -mtime +3 -delete

# раз в неделю быстрая проверка целостности репозитория
if [ "$(date +%u)" = "7" ]; then restic check --read-data-subset=5%; fi
