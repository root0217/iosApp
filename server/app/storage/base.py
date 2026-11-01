"""Контракт StorageProvider. Всё приложение работает только через него; конкретное хранилище подменяется реализацией."""
from abc import ABC, abstractmethod
from collections.abc import AsyncIterator
from dataclasses import dataclass


@dataclass(frozen=True)
class StoredObject:
    key: str
    size: int
    sha256: str


@dataclass(frozen=True)
class ObjectInfo:
    key: str
    size: int
    mtime: float


class StorageError(Exception):
    pass


class ObjectNotFound(StorageError):
    pass


class InvalidKey(StorageError):
    pass


class OffsetMismatch(StorageError):
    def __init__(self, expected: int):
        super().__init__(f"expected offset {expected}")
        self.expected = expected


class StorageProvider(ABC):
    name: str

    @abstractmethod
    def new_key(self) -> str:
        """Новый непредсказуемый ключ объекта (не зависит от имени файла пользователя)."""

    # --- «черновик» загрузки (для докачки): запись строго последовательная ---
    @abstractmethod
    async def staging_begin(self, upload_id: str) -> None: ...

    @abstractmethod
    async def staging_size(self, upload_id: str) -> int: ...

    @abstractmethod
    async def staging_truncate(self, upload_id: str, size: int) -> None:
        """Отрезает «хвост» после size (нужно при докачке, если прошлый запрос оборвался)."""

    @abstractmethod
    async def staging_write(self, upload_id: str, offset: int, data: bytes) -> int:
        """Дописывает данные. offset обязан совпадать с текущим размером, иначе OffsetMismatch. Возвращает новый размер."""

    @abstractmethod
    async def staging_commit(self, upload_id: str, key: str) -> StoredObject:
        """Атомарно превращает черновик в объект key; считает SHA-256."""

    @abstractmethod
    async def staging_abort(self, upload_id: str) -> None: ...

    # --- объекты ---
    @abstractmethod
    async def stat(self, key: str) -> int:
        """Размер объекта или ObjectNotFound."""

    @abstractmethod
    def iter_range(self, key: str, start: int, end: int) -> AsyncIterator[bytes]:
        """Байты [start, end] включительно."""

    @abstractmethod
    async def delete(self, key: str) -> None:
        """Идемпотентно: отсутствие объекта не ошибка."""

    @abstractmethod
    async def list_objects(self) -> list[ObjectInfo]: ...
