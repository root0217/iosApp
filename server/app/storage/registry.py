from functools import lru_cache

from ..config import get_settings
from .base import StorageError, StorageProvider
from .local import LocalStorageProvider


@lru_cache
def _providers() -> dict[str, StorageProvider]:
    s = get_settings()
    # Сюда добавляются другие провайдеры (S3-совместимые и т.д.), клиентское приложение при этом не меняется.
    return {"local": LocalStorageProvider(s.data_dir)}


def get_provider(name: str) -> StorageProvider:
    try:
        return _providers()[name]
    except KeyError:
        raise StorageError(f"unknown storage provider: {name}") from None


def default_provider() -> StorageProvider:
    return get_provider(get_settings().default_storage)
