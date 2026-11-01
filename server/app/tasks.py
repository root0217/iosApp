"""Фоновые задачи: корзина, брошенные загрузки, сверка хранилища с БД."""
import asyncio
import logging
import time
from datetime import timedelta

from sqlalchemy import select

from . import db
from .config import get_settings
from .library import service as svc
from .models import File, UploadSession, utcnow
from .storage.registry import default_provider, get_provider

log = logging.getLogger("app.tasks")


async def purge_trash() -> None:
    cutoff = utcnow() - timedelta(days=get_settings().trash_retention_days)
    async with db.SessionLocal() as session:
        keys = await svc.purge_expired(session, cutoff)
        await session.commit()
    for prov, key in keys:
        try:
            await get_provider(prov).delete(key)
        except Exception:
            log.exception("не удалось удалить %s/%s", prov, key)
    if keys:
        log.info("корзина: окончательно удалено объектов: %d", len(keys))


async def cleanup_uploads() -> None:
    storage = default_provider()
    async with db.SessionLocal() as session:
        rows = (await session.execute(select(UploadSession).where(UploadSession.expires_at < utcnow()))).scalars().all()
        for up in rows:
            await storage.staging_abort(str(up.id))
            await session.delete(up)
        await session.commit()
    if rows:
        log.info("брошенных загрузок очищено: %d", len(rows))


async def sweep_orphans() -> None:
    """Объекты в хранилище без записи в БД удаляем (старше grace-периода); записи без объекта только логируем."""
    storage = default_provider()
    async with db.SessionLocal() as session:
        db_keys = set((await session.execute(select(File.storage_key).where(File.storage_provider == storage.name))).scalars())
    objects = await storage.list_objects()
    stored = {o.key for o in objects}
    cutoff = time.time() - get_settings().orphan_grace_hours * 3600
    removed = 0
    for o in objects:
        if o.key not in db_keys and o.mtime < cutoff:
            await storage.delete(o.key)
            removed += 1
    missing = db_keys - stored
    if removed:
        log.info("сверка: удалено осиротевших объектов: %d", removed)
    if missing:
        log.error("сверка: в БД есть %d файлов, которых нет в хранилище (нужно восстановление из бэкапа)", len(missing))


async def _every(seconds: float, initial_delay: float, fn, name: str) -> None:
    await asyncio.sleep(initial_delay)
    while True:
        try:
            await fn()
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("фоновая задача %s упала", name)
        await asyncio.sleep(seconds)


def start_background_tasks() -> list[asyncio.Task]:
    return [
        asyncio.create_task(_every(3600, 60, purge_trash, "purge_trash")),
        asyncio.create_task(_every(3600, 120, cleanup_uploads, "cleanup_uploads")),
        asyncio.create_task(_every(24 * 3600, 600, sweep_orphans, "sweep_orphans")),
    ]
