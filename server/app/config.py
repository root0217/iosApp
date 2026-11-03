from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://app:app@db:5432/app"
    secret_key: str                      # обязателен: без него сервер не стартует
    enable_docs: bool = False            # /docs и /openapi.json

    # Регистрация открытая (как требует ТЗ про аккаунт Chapa) — никакого setup-токена больше нет.
    # Единственный способ получить аккаунт с is_admin=True — CLI app/manage.py create-owner,
    # он пишет в БД напрямую и в этот процесс не заходит.
    pending_registration_ttl_minutes: int = 15

    data_dir: Path = Path("/data")
    default_storage: str = "local"
    max_upload_bytes: int = 20 * 1024**3
    avatar_max_source_bytes: int = 10 * 1024**2
    avatar_output_size: int = 512         # сторона итогового квадратного JPEG

    access_ttl_minutes: int = 15
    refresh_ttl_days: int = 60
    download_link_ttl_seconds: int = 300

    login_max_attempts: int = 3
    login_lockout_minutes: int = 15       # удваивается при повторных срывах, см. auth/router.py

    trash_retention_days: int = 30
    upload_session_ttl_hours: int = 168
    orphan_grace_hours: int = 24


@lru_cache
def get_settings() -> Settings:
    return Settings()
