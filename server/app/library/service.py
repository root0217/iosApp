"""Бизнес-логика библиотеки. Никакого HTTP: только БД и правила (удобно переиспользовать из бота и фоновых задач)."""
from __future__ import annotations

import uuid
from collections.abc import Iterable
from datetime import datetime

from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..models import Change, File, Folder, utcnow
from ..names import unique_name


class NotFound(Exception):
    def __init__(self, what: str = "object"):
        super().__init__(what)
        self.what = what


class Conflict(Exception):
    def __init__(self, code: str, **extra):
        super().__init__(code)
        self.code = code
        self.extra = extra


def _eq_or_null(col, val):
    return col.is_(None) if val is None else col == val


async def record(session: AsyncSession, user_id: uuid.UUID, entity_type: str, ids: Iterable[uuid.UUID], op: str) -> None:
    session.add_all([Change(user_id=user_id, entity_type=entity_type, entity_id=i, op=op) for i in ids])


# ---------- чтение ----------
async def get_folder(session: AsyncSession, user_id: uuid.UUID, folder_id: uuid.UUID, *, deleted: bool = False) -> Folder:
    q = select(Folder).where(Folder.id == folder_id, Folder.user_id == user_id)
    q = q.where(Folder.deleted_at.is_not(None) if deleted else Folder.deleted_at.is_(None))
    obj = (await session.execute(q)).scalar_one_or_none()
    if obj is None:
        raise NotFound("folder")
    return obj


async def get_file(session: AsyncSession, user_id: uuid.UUID, file_id: uuid.UUID, *, deleted: bool = False) -> File:
    q = select(File).where(File.id == file_id, File.user_id == user_id)
    q = q.where(File.deleted_at.is_not(None) if deleted else File.deleted_at.is_(None))
    obj = (await session.execute(q)).scalar_one_or_none()
    if obj is None:
        raise NotFound("file")
    return obj


async def breadcrumbs(session: AsyncSession, user_id: uuid.UUID, folder: Folder) -> list[Folder]:
    chain, seen, cur = [folder], {folder.id}, folder
    while cur.parent_id is not None:
        cur = await get_folder(session, user_id, cur.parent_id)
        if cur.id in seen:
            break
        seen.add(cur.id)
        chain.append(cur)
    chain.reverse()
    return chain


async def live_names(
    session: AsyncSession,
    user_id: uuid.UUID,
    parent_id: uuid.UUID | None,
    *,
    exclude_file: uuid.UUID | None = None,
    exclude_folder: uuid.UUID | None = None,
) -> set[str]:
    fq = select(func.lower(File.name)).where(File.user_id == user_id, File.deleted_at.is_(None),
                                             File.is_message_attachment.is_(False), _eq_or_null(File.folder_id, parent_id))
    dq = select(func.lower(Folder.name)).where(Folder.user_id == user_id, Folder.deleted_at.is_(None), _eq_or_null(Folder.parent_id, parent_id))
    if exclude_file:
        fq = fq.where(File.id != exclude_file)
    if exclude_folder:
        dq = dq.where(Folder.id != exclude_folder)
    names = set((await session.execute(fq)).scalars())
    names |= set((await session.execute(dq)).scalars())
    return names


async def ensure_free(session: AsyncSession, user_id, parent_id, name: str, **exclude) -> None:
    if name.lower() in await live_names(session, user_id, parent_id, **exclude):
        raise Conflict("name_conflict", name=name)


async def subtree_folder_ids(session: AsyncSession, user_id: uuid.UUID, root_id: uuid.UUID) -> list[uuid.UUID]:
    """Все живые вложенные папки (без самой root)."""
    found: list[uuid.UUID] = []
    frontier = [root_id]
    while frontier:
        q = select(Folder.id).where(Folder.user_id == user_id, Folder.parent_id.in_(frontier), Folder.deleted_at.is_(None))
        frontier = list((await session.execute(q)).scalars())
        found += frontier
    return found


# ---------- корзина ----------
async def trash_file(session: AsyncSession, user_id: uuid.UUID, f: File) -> None:
    now = utcnow()
    f.deleted_at, f.deleted_via, f.updated_at = now, None, now
    f.version += 1
    await record(session, user_id, "file", [f.id], "delete")


async def trash_folder(session: AsyncSession, user_id: uuid.UUID, folder: Folder) -> None:
    now = utcnow()
    sub = await subtree_folder_ids(session, user_id, folder.id)
    all_ids = [folder.id, *sub]
    file_ids = list(
        (await session.execute(select(File.id).where(File.user_id == user_id, File.folder_id.in_(all_ids), File.deleted_at.is_(None)))).scalars()
    )
    if sub:
        await session.execute(update(Folder).where(Folder.id.in_(sub)).values(deleted_at=now, deleted_via=folder.id, updated_at=now))
    if file_ids:
        await session.execute(update(File).where(File.id.in_(file_ids)).values(deleted_at=now, deleted_via=folder.id, updated_at=now))
    folder.deleted_at, folder.deleted_via, folder.updated_at = now, None, now
    folder.version += 1
    await record(session, user_id, "folder", all_ids, "delete")
    await record(session, user_id, "file", file_ids, "delete")


async def _folder_is_live(session: AsyncSession, user_id: uuid.UUID, folder_id: uuid.UUID | None) -> bool:
    if folder_id is None:
        return True
    return await session.scalar(select(Folder.id).where(Folder.id == folder_id, Folder.user_id == user_id, Folder.deleted_at.is_(None))) is not None


async def restore_file(session: AsyncSession, user_id: uuid.UUID, f: File) -> None:
    if not await _folder_is_live(session, user_id, f.folder_id):
        f.folder_id = None  # исходная папка удалена: восстанавливаем в корень
    f.name = unique_name(f.name, await live_names(session, user_id, f.folder_id))
    f.deleted_at, f.deleted_via, f.updated_at = None, None, utcnow()
    f.version += 1
    await record(session, user_id, "file", [f.id], "upsert")


async def restore_folder(session: AsyncSession, user_id: uuid.UUID, root: Folder) -> None:
    if not await _folder_is_live(session, user_id, root.parent_id):
        root.parent_id = None
    root.name = unique_name(root.name, await live_names(session, user_id, root.parent_id), is_file=False)
    now = utcnow()
    sub_ids = list((await session.execute(select(Folder.id).where(Folder.user_id == user_id, Folder.deleted_via == root.id))).scalars())
    file_ids = list((await session.execute(select(File.id).where(File.user_id == user_id, File.deleted_via == root.id))).scalars())
    if sub_ids:
        await session.execute(update(Folder).where(Folder.id.in_(sub_ids)).values(deleted_at=None, deleted_via=None, updated_at=now))
    if file_ids:
        await session.execute(update(File).where(File.id.in_(file_ids)).values(deleted_at=None, deleted_via=None, updated_at=now))
    root.deleted_at, root.deleted_via, root.updated_at = None, None, now
    root.version += 1
    await record(session, user_id, "folder", [root.id, *sub_ids], "upsert")
    await record(session, user_id, "file", file_ids, "upsert")


async def purge_file(session: AsyncSession, f: File) -> list[tuple[str, str]]:
    """Удаляет запись; возвращает (provider, key) объектов, которые нужно удалить из хранилища ПОСЛЕ коммита."""
    keys = [(f.storage_provider, f.storage_key)]
    await session.delete(f)
    await session.flush()
    return keys


async def purge_folder(session: AsyncSession, user_id: uuid.UUID, root: Folder) -> list[tuple[str, str]]:
    files = (await session.execute(select(File).where(File.user_id == user_id, File.deleted_via == root.id))).scalars().all()
    keys = [(f.storage_provider, f.storage_key) for f in files]
    if files:
        await session.execute(delete(File).where(File.id.in_([f.id for f in files])))
    await session.execute(delete(Folder).where(Folder.user_id == user_id, or_(Folder.deleted_via == root.id, Folder.id == root.id)))
    return keys


async def purge_expired(session: AsyncSession, cutoff: datetime) -> list[tuple[str, str]]:
    keys: list[tuple[str, str]] = []
    folders = (await session.execute(select(Folder).where(Folder.deleted_at < cutoff, Folder.deleted_via.is_(None)))).scalars().all()
    for fo in folders:
        keys += await purge_folder(session, fo.user_id, fo)
    files = (await session.execute(select(File).where(File.deleted_at < cutoff, File.deleted_via.is_(None)))).scalars().all()
    for f in files:
        keys += await purge_file(session, f)
    return keys


# ---------- лента изменений ----------
async def changes_since(session: AsyncSession, user_id: uuid.UUID, cursor: int, limit: int):
    rows = (
        await session.execute(select(Change).where(Change.user_id == user_id, Change.seq > cursor).order_by(Change.seq).limit(limit + 1))
    ).scalars().all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    file_ids = {r.entity_id for r in rows if r.entity_type == "file" and r.op == "upsert"}
    folder_ids = {r.entity_id for r in rows if r.entity_type == "folder" and r.op == "upsert"}
    files = {}
    folders = {}
    if file_ids:
        files = {f.id: f for f in (await session.execute(select(File).where(File.id.in_(file_ids), File.deleted_at.is_(None)))).scalars()}
    if folder_ids:
        folders = {f.id: f for f in (await session.execute(select(Folder).where(Folder.id.in_(folder_ids), Folder.deleted_at.is_(None)))).scalars()}
    out = []
    for r in rows:
        file = folder = None
        op = r.op
        if op == "upsert":
            file = files.get(r.entity_id) if r.entity_type == "file" else None
            folder = folders.get(r.entity_id) if r.entity_type == "folder" else None
            if file is None and folder is None:
                op = "delete"  # к моменту запроса объект уже удалён
        out.append((r, op, file, folder))
    new_cursor = rows[-1].seq if rows else cursor
    return out, new_cursor, has_more


# ---------- сбор записей для ZIP ----------
async def collect_zip_entries(session: AsyncSession, user_id: uuid.UUID, file_ids: list[uuid.UUID], folder_ids: list[uuid.UUID]):
    """Возвращает список (arcname, is_dir, mtime, provider, key). Имена верхнего уровня делаются уникальными."""
    entries: list[tuple[str, bool, datetime, str | None, str | None]] = []
    taken: set[str] = set()
    for fid in file_ids:
        f = await get_file(session, user_id, fid)
        name = unique_name(f.name, taken)
        taken.add(name.lower())
        entries.append((name, False, f.updated_at, f.storage_provider, f.storage_key))
    for did in folder_ids:
        root = await get_folder(session, user_id, did)
        name = unique_name(root.name, taken, is_file=False)
        taken.add(name.lower())
        entries.append((name, True, root.updated_at, None, None))
        frontier = {root.id: name}
        while frontier:
            ids = list(frontier)
            for f in (await session.execute(select(File).where(File.user_id == user_id, File.folder_id.in_(ids), File.deleted_at.is_(None)))).scalars():
                entries.append((f"{frontier[f.folder_id]}/{f.name}", False, f.updated_at, f.storage_provider, f.storage_key))
            nxt: dict[uuid.UUID, str] = {}
            for s in (await session.execute(select(Folder).where(Folder.user_id == user_id, Folder.parent_id.in_(ids), Folder.deleted_at.is_(None)))).scalars():
                path = f"{frontier[s.parent_id]}/{s.name}"
                entries.append((path, True, s.updated_at, None, None))
                nxt[s.id] = path
            frontier = nxt
    return entries
