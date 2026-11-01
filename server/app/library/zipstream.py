"""Потоковая сборка ZIP «на лету»: файл не копируется на диск целиком, память не растёт."""
import zipfile
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass


@dataclass
class ZipEntry:
    arcname: str                                           # путь внутри архива, через «/»
    date_time: tuple[int, int, int, int, int, int]
    chunks: Callable[[], AsyncIterator[bytes]] | None = None  # None → пустая папка


class _Sink:
    def __init__(self) -> None:
        self._buf = bytearray()
        self._pos = 0

    def write(self, b: bytes) -> int:
        self._buf += b
        self._pos += len(b)
        return len(b)

    def tell(self) -> int:  # без seek() zipfile переходит в потоковый режим (data descriptors)
        return self._pos

    def flush(self) -> None:
        pass

    def drain(self) -> bytes:
        data = bytes(self._buf)
        self._buf.clear()
        return data


def clamp_date(dt: tuple[int, int, int, int, int, int]) -> tuple[int, int, int, int, int, int]:
    return dt if dt[0] >= 1980 else (1980, 1, 1, 0, 0, 0)


async def stream_zip(entries: list[ZipEntry]) -> AsyncIterator[bytes]:
    sink = _Sink()
    zf = zipfile.ZipFile(sink, mode="w", compression=zipfile.ZIP_STORED, allowZip64=True)
    for e in entries:
        if e.chunks is None:
            zi = zipfile.ZipInfo(e.arcname.rstrip("/") + "/", date_time=clamp_date(e.date_time))
            zi.external_attr = (0o40755 << 16) | 0x10
            zf.writestr(zi, b"")
            data = sink.drain()
            if data:
                yield data
            continue
        zi = zipfile.ZipInfo(e.arcname, date_time=clamp_date(e.date_time))
        zi.compress_type = zipfile.ZIP_STORED
        zi.external_attr = 0o644 << 16
        with zf.open(zi, "w", force_zip64=True) as w:
            async for chunk in e.chunks():
                w.write(chunk)
                data = sink.drain()
                if data:
                    yield data
        data = sink.drain()
        if data:
            yield data
    zf.close()
    data = sink.drain()
    if data:
        yield data
