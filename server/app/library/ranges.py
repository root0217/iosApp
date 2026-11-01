"""Разбор HTTP-заголовка Range (один диапазон) для докачки и перемотки аудио/видео."""
import re


class RangeNotSatisfiable(Exception):
    pass


_RE = re.compile(r"bytes=(\d*)-(\d*)")


def parse_range(header: str | None, size: int) -> tuple[int, int] | None:
    """None: отдавать файл целиком. (start, end): отдавать диапазон включительно.
    RangeNotSatisfiable: ответить 416. Несколько диапазонов и мусор игнорируются (отдаём целиком, это разрешено RFC)."""
    if not header or size == 0:
        return None
    m = _RE.fullmatch(header.strip())
    if not m:
        return None
    s, e = m.groups()
    if s == "" and e == "":
        return None
    if s == "":  # суффикс: последние N байт
        n = int(e)
        if n == 0:
            raise RangeNotSatisfiable
        return max(size - n, 0), size - 1
    start = int(s)
    if start >= size:
        raise RangeNotSatisfiable
    end = int(e) if e else size - 1
    if end < start:
        return None
    return start, min(end, size - 1)
