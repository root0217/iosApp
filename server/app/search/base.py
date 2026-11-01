from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import dataclass, field
from typing import Protocol

log = logging.getLogger("app.search")


@dataclass
class SearchHit:
    type: str                     # "file" | "folder" | (позже) "track", "artist", "album", "playlist", "chat", "message", ...
    id: str
    title: str
    subtitle: str | None = None
    score: float = 0.0
    extra: dict = field(default_factory=dict)  # данные для перехода к объекту (например, folder_id)


class SearchProvider(Protocol):
    """Каждый модуль приложения реализует этот интерфейс и регистрируется в реестре."""

    name: str

    async def search(self, user_id: uuid.UUID, query: str, limit: int) -> list[SearchHit]: ...


class SearchRegistry:
    def __init__(self) -> None:
        self._providers: list[SearchProvider] = []

    def register(self, provider: SearchProvider) -> None:
        self._providers.append(provider)

    @property
    def providers(self) -> list[SearchProvider]:
        return list(self._providers)

    async def search(self, user_id: uuid.UUID, query: str, limit: int, *, only: set[str] | None = None, timeout: float = 3.0):
        """Параллельный поиск по всем модулям. Сбой или таймаут одного источника не ломает остальные."""

        async def one(p: SearchProvider):
            try:
                hits = await asyncio.wait_for(p.search(user_id, query, limit), timeout)
                return p.name, hits, None
            except Exception as e:  # noqa: BLE001
                log.warning("поисковый источник %s недоступен: %r", p.name, e)
                return p.name, [], type(e).__name__

        active = [p for p in self._providers if only is None or p.name in only]
        results = await asyncio.gather(*(one(p) for p in active))
        hits = sorted((h for _, hs, _ in results for h in hs), key=lambda h: h.score, reverse=True)[:limit]
        sources = {name: {"ok": err is None, "count": len(hs), "error": err} for name, hs, err in results}
        return hits, sources


registry = SearchRegistry()
