"""Безопасная обработка имён файлов и папок."""
import re
import unicodedata

MAX_NAME = 255


class InvalidName(ValueError):
    pass


# управляющие символы + невидимые bidi-метки (подмена расширения вроде «txt.exe» через RTL-override)
_BAD = re.compile(r"[\x00-\x1f\x7f\u200b-\u200f\u202a-\u202e\u2066-\u2069]")


def split_ext(name: str) -> tuple[str, str]:
    """('report', 'pdf') для 'report.pdf'. Скрытые файлы (.bashrc) и слишком длинные «расширения» считаются без расширения."""
    stem, dot, ext = name.rpartition(".")
    if not dot or not stem or len(ext) > 16:
        return name, ""
    return stem, ext


def safe_name(raw: str | None) -> str:
    name = unicodedata.normalize("NFC", raw or "")
    name = _BAD.sub("", name).replace("/", "_").replace("\\", "_").strip()
    if name in ("", ".", ".."):
        raise InvalidName("invalid name")
    if len(name) > MAX_NAME:
        stem, ext = split_ext(name)
        if ext:
            name = stem[: MAX_NAME - len(ext) - 1] + "." + ext
        else:
            name = name[:MAX_NAME]
        name = name.strip()
        if not name:
            raise InvalidName("invalid name")
    return name


def unique_name(name: str, taken_lower: set[str], *, is_file: bool = True) -> str:
    """Если имя занято, добавляет « (1)», « (2)»… перед расширением. taken_lower: имена в нижнем регистре."""
    if name.lower() not in taken_lower:
        return name
    stem, ext = split_ext(name) if is_file else (name, "")
    suffix = f".{ext}" if ext else ""
    n = 1
    while True:
        candidate = f"{stem} ({n}){suffix}"
        if candidate.lower() not in taken_lower:
            return candidate
        n += 1
