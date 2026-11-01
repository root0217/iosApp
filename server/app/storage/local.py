import asyncio
import hashlib
import os
import re
import uuid
from collections.abc import AsyncIterator
from pathlib import Path

from .base import InvalidKey, ObjectInfo, ObjectNotFound, OffsetMismatch, StorageProvider, StoredObject

CHUNK = 1024 * 1024
_KEY_RE = re.compile(r"^[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{32}$")
_ID_RE = re.compile(r"^[0-9a-fA-F-]{32,36}$")


class LocalStorageProvider(StorageProvider):
    """Файлы на локальном диске: <root>/objects/ab/cd/<uuid-hex>, черновики загрузок в <root>/staging/.

    objects и staging лежат на одном томе, поэтому os.replace атомарен.
    """

    name = "local"

    def __init__(self, root: Path):
        self.root = Path(root).resolve()
        self.objects = self.root / "objects"
        self.staging = self.root / "staging"
        self.objects.mkdir(parents=True, exist_ok=True)
        self.staging.mkdir(parents=True, exist_ok=True)

    # --- пути (единственное место, где ключ превращается в путь) ---
    def new_key(self) -> str:
        h = uuid.uuid4().hex
        return f"{h[:2]}/{h[2:4]}/{h}"

    def _obj(self, key: str) -> Path:
        if not isinstance(key, str) or not _KEY_RE.fullmatch(key):
            raise InvalidKey(f"invalid key: {key!r}")
        path = (self.objects / key).resolve()
        if not path.is_relative_to(self.objects):
            raise InvalidKey("path traversal")
        return path

    def _stg(self, upload_id: str) -> Path:
        if not isinstance(upload_id, str) or not _ID_RE.fullmatch(upload_id):
            raise InvalidKey(f"invalid upload id: {upload_id!r}")
        return self.staging / f"{upload_id}.part"

    # --- черновики ---
    async def staging_begin(self, upload_id: str) -> None:
        p = self._stg(upload_id)
        await asyncio.to_thread(lambda: open(p, "ab").close())

    async def staging_size(self, upload_id: str) -> int:
        p = self._stg(upload_id)
        try:
            return await asyncio.to_thread(lambda: os.stat(p).st_size)
        except FileNotFoundError:
            raise ObjectNotFound(upload_id) from None

    async def staging_truncate(self, upload_id: str, size: int) -> None:
        p = self._stg(upload_id)

        def work() -> None:
            try:
                f = open(p, "r+b")
            except FileNotFoundError:
                raise ObjectNotFound(upload_id) from None
            with f:
                cur = os.fstat(f.fileno()).st_size
                if size > cur:
                    raise OffsetMismatch(cur)
                f.truncate(size)

        await asyncio.to_thread(work)

    async def staging_write(self, upload_id: str, offset: int, data: bytes) -> int:
        p = self._stg(upload_id)

        def work() -> int:
            try:
                f = open(p, "r+b")
            except FileNotFoundError:
                raise ObjectNotFound(upload_id) from None
            with f:
                cur = os.fstat(f.fileno()).st_size
                if offset != cur:
                    raise OffsetMismatch(cur)
                f.seek(offset)
                f.write(data)
                f.flush()
                return cur + len(data)

        return await asyncio.to_thread(work)

    async def staging_commit(self, upload_id: str, key: str) -> StoredObject:
        src = self._stg(upload_id)
        dst = self._obj(key)

        def work() -> StoredObject:
            h = hashlib.sha256()
            size = 0
            try:
                f = open(src, "rb")
            except FileNotFoundError:
                raise ObjectNotFound(upload_id) from None
            with f:
                while chunk := f.read(CHUNK):
                    h.update(chunk)
                    size += len(chunk)
                os.fsync(f.fileno())
            dst.parent.mkdir(parents=True, exist_ok=True)
            os.replace(src, dst)
            os.utime(dst, None)  # mtime = момент фиксации (важно для сверки «осиротевших» объектов)
            return StoredObject(key=key, size=size, sha256=h.hexdigest())

        return await asyncio.to_thread(work)

    async def staging_abort(self, upload_id: str) -> None:
        p = self._stg(upload_id)
        await asyncio.to_thread(lambda: p.unlink(missing_ok=True))

    # --- объекты ---
    async def stat(self, key: str) -> int:
        p = self._obj(key)
        try:
            return await asyncio.to_thread(lambda: os.stat(p).st_size)
        except FileNotFoundError:
            raise ObjectNotFound(key) from None

    async def iter_range(self, key: str, start: int, end: int) -> AsyncIterator[bytes]:
        p = self._obj(key)
        try:
            f = await asyncio.to_thread(open, p, "rb")
        except FileNotFoundError:
            raise ObjectNotFound(key) from None
        try:
            await asyncio.to_thread(f.seek, start)
            remaining = end - start + 1
            while remaining > 0:
                data = await asyncio.to_thread(f.read, min(CHUNK, remaining))
                if not data:
                    break
                remaining -= len(data)
                yield data
        finally:
            f.close()

    async def delete(self, key: str) -> None:
        p = self._obj(key)
        await asyncio.to_thread(lambda: p.unlink(missing_ok=True))

    async def list_objects(self) -> list[ObjectInfo]:
        def work() -> list[ObjectInfo]:
            out: list[ObjectInfo] = []
            for dirpath, _dirs, files in os.walk(self.objects):
                for fn in files:
                    full = Path(dirpath) / fn
                    key = full.relative_to(self.objects).as_posix()
                    if not _KEY_RE.fullmatch(key):
                        continue
                    st = full.stat()
                    out.append(ObjectInfo(key=key, size=st.st_size, mtime=st.st_mtime))
            return out

        return await asyncio.to_thread(work)
