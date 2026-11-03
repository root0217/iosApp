"""Зарезервированные username: нельзя занять ни при регистрации, ни при смене имени.
Владелец (chapa) создаётся отдельным CLI в обход этой проверки — см. app/manage.py."""

RESERVED_USERNAMES: frozenset[str] = frozenset({
    "admin", "administrator", "admins", "root", "support", "help",
    "system", "systems", "chapa", "official", "moderator", "moderators", "mod",
    "staff", "team", "owner", "security", "null", "undefined", "none",
    "api", "www", "ftp", "mail", "email", "test", "guest", "anonymous",
    "bot", "bots", "service", "info", "contact", "abuse", "legal", "privacy",
    "terms", "billing", "deleted", "deleted_user", "me", "you", "user", "users",
    "chapaapp", "chapa_official",
})
