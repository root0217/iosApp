import logging
from collections.abc import AsyncIterator

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

log = logging.getLogger("app.db")


class Base(DeclarativeBase):
    pass


engine: AsyncEngine | None = None
SessionLocal: async_sessionmaker[AsyncSession] | None = None


def init_engine(url: str) -> None:
    global engine, SessionLocal
    engine = create_async_engine(url, pool_pre_ping=True, pool_size=10, max_overflow=10)
    SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


async def create_schema() -> None:
    """Создаёт таблицы при старте. Перед первым изменением схемы в проде нужно перейти на Alembic."""
    from . import models  # noqa: F401  (регистрирует таблицы в Base.metadata)

    assert engine is not None
    try:
        async with engine.begin() as conn:
            await conn.execute(text("CREATE EXTENSION IF NOT EXISTS pg_trgm"))
    except Exception:
        log.warning("pg_trgm недоступен: поиск по подстроке будет медленнее", exc_info=True)

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    for ddl in (
        "CREATE INDEX IF NOT EXISTS ix_files_name_trgm ON files USING gin (name gin_trgm_ops)",
        "CREATE INDEX IF NOT EXISTS ix_folders_name_trgm ON folders USING gin (name gin_trgm_ops)",
    ):
        try:
            async with engine.begin() as conn:
                await conn.execute(text(ddl))
        except Exception:
            log.warning("не удалось создать индекс: %s", ddl, exc_info=True)


async def get_session() -> AsyncIterator[AsyncSession]:
    assert SessionLocal is not None
    async with SessionLocal() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
