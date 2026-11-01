from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://app:app@db:5432/app"
    secret_key: str                      # обязателен: без него сервер не стартует
    setup_token: str = ""                # без него регистрация полностью закрыта
    allow_registration: bool = False     # второго и следующих пользователей можно создать, только если true
    enable_docs: bool = False            # /docs и /openapi.json

    data_dir: Path = Path("/data")
    default_storage: str = "local"
    max_upload_bytes: int = 20 * 1024**3

    access_ttl_minutes: int = 15
    refresh_ttl_days: int = 60
    download_link_ttl_seconds: int = 300

    trash_retention_days: int = 30
    upload_session_ttl_hours: int = 168
    orphan_grace_hours: int = 24


@lru_cache
def get_settings() -> Settings:
    return Settings()
