from __future__ import annotations

import uuid

from sqlalchemy import select

from .. import db
from ..models import File, Folder
from .base import SearchHit


def _esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _score(name: str, query: str) -> float:
    n, q = name.lower(), query.lower().strip()
    if n == q:
        return 1.0
    if n.startswith(q):
        return 0.8
    return 0.5


class LibrarySearchProvider:
    name = "library"

    async def search(self, user_id: uuid.UUID, query: str, limit: int) -> list[SearchHit]:
        words = [w for w in query.split() if w][:6]
        if not words:
            return []
        assert db.SessionLocal is not None
        async with db.SessionLocal() as session:  # своя сессия: поиск идёт параллельно с другими модулями
            files = (
                await session.execute(
                    select(File).where(File.user_id == user_id, File.deleted_at.is_(None),
                                       *[File.name.ilike(f"%{_esc(w)}%", escape="\\") for w in words]).limit(limit)
                )
            ).scalars().all()
            folders = (
                await session.execute(
                    select(Folder).where(Folder.user_id == user_id, Folder.deleted_at.is_(None),
                                         *[Folder.name.ilike(f"%{_esc(w)}%", escape="\\") for w in words]).limit(limit)
                )
            ).scalars().all()
        hits = [
            SearchHit("folder", str(f.id), f.name, None, _score(f.name, query), {"parent_id": str(f.parent_id) if f.parent_id else None})
            for f in folders
        ]
        hits += [
            SearchHit("file", str(f.id), f.name, f.mime_type, _score(f.name, query),
                      {"folder_id": str(f.folder_id) if f.folder_id else None, "size_bytes": f.size_bytes})
            for f in files
        ]
        return hits
