"""Правила username и пароля из ТЗ. Никакой кириллицы и пробелов нигде."""
import re

from .reserved import RESERVED_USERNAMES

_USERNAME_CHARS = re.compile(r"^[a-z0-9_.]{3,30}$")
_PASSWORD_CHARS = re.compile(r"^[A-Za-z0-9!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~]{8,128}$")


def normalize_username(raw: str) -> str:
    return raw.strip().lower()


def username_error(username: str) -> str | None:
    """None = имя корректно по формату (доступность проверяется отдельно в БД)."""
    if not _USERNAME_CHARS.fullmatch(username):
        return "invalid_format"
    if username[0] == "." or username[-1] == ".":
        return "dot_at_edge"
    if ".." in username:
        return "consecutive_dots"
    if username in RESERVED_USERNAMES:
        return "reserved"
    return None


def password_error(password: str) -> str | None:
    if not _PASSWORD_CHARS.fullmatch(password):
        return "invalid_characters"
    return None
