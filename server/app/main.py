import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text

from . import db
from .auth.router import router as auth_router
from .config import get_settings
from .library import service as lib_service
from .library.router import router as library_router
from .messenger.router import router as messenger_router
from .messenger.ws_router import router as messenger_ws_router
from .names import InvalidName
from .search.base import registry as search_registry
from .search.library_provider import LibrarySearchProvider
from .search.router import router as search_router
from .storage.base import StorageError
from .tasks import start_background_tasks

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("app")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    db.init_engine(settings.database_url)
    await db.create_schema()
    search_registry.register(LibrarySearchProvider())  # новые модули (музыка, чаты…) регистрируют себя так же
    tasks = start_background_tasks()
    log.info("сервер запущен")
    yield
    for t in tasks:
        t.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    await db.engine.dispose()


_s = get_settings()
app = FastAPI(
    title="Personal server API",
    version="0.1.0",
    lifespan=lifespan,
    docs_url="/docs" if _s.enable_docs else None,
    redoc_url=None,
    openapi_url="/openapi.json" if _s.enable_docs else None,
)

app.include_router(auth_router, prefix="/v1")
app.include_router(library_router, prefix="/v1")
app.include_router(messenger_router, prefix="/v1")
app.include_router(messenger_ws_router, prefix="/v1")
app.include_router(search_router, prefix="/v1")


@app.exception_handler(lib_service.NotFound)
async def _not_found(_: Request, exc: lib_service.NotFound):
    return JSONResponse(status_code=404, content={"detail": {"code": "not_found", "what": exc.what}})


@app.exception_handler(lib_service.Conflict)
async def _conflict(_: Request, exc: lib_service.Conflict):
    return JSONResponse(status_code=409, content={"detail": {"code": exc.code, **exc.extra}})


@app.exception_handler(InvalidName)
async def _invalid_name(_: Request, exc: InvalidName):
    return JSONResponse(status_code=422, content={"detail": {"code": "invalid_name"}})


@app.exception_handler(StorageError)
async def _storage_error(_: Request, exc: StorageError):
    log.error("ошибка хранилища: %r", exc)
    return JSONResponse(status_code=503, content={"detail": {"code": "storage_error"}})


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("Referrer-Policy", "no-referrer")
    return response


@app.get("/healthz", include_in_schema=False)
async def healthz():
    async with db.SessionLocal() as session:
        await session.execute(text("SELECT 1"))
    return {"status": "ok"}
