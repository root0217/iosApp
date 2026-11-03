"""Recovery-код: длинный случайный код, который пользователь вводит для подтверждения
при регистрации и позже для восстановления пароля/username.

Почему не Argon2id, как у пароля: recovery-код сам по себе уже высокоэнтропийный
случайный секрет (а не то, что человек мог придумать и переиспользовать), поэтому
не нужна медленная память-жёсткая защита от подбора. Зато нужен поиск «по какому
пользователю этот код» для сценария «забыл username» — Argon2id для этого не подходит,
он намеренно не даёт восстановить, у какой записи совпадёт хэш, без перебора всех
пользователей. Решение: HMAC-SHA256 с серверным секретом — детерминированный,
быстрый, с ним можно искать по точному совпадению в БД, и без секрета его не подделать
и не обратить."""
import hmac
import secrets
from hashlib import sha256

_GROUP_SIZES = (6, 6, 6, 6)  # 24 символа, по 6 через дефис


def generate_recovery_code() -> str:
    alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # без похожих друг на друга символов (нет O/0, I/1/L)
    groups = ["".join(secrets.choice(alphabet) for _ in range(n)) for n in _GROUP_SIZES]
    return "-".join(groups)


def normalize_recovery_code(raw: str) -> str:
    return raw.strip().upper()


def hash_recovery_code(secret_key: str, code: str) -> str:
    normalized = normalize_recovery_code(code)
    return hmac.new(secret_key.encode(), normalized.encode(), sha256).hexdigest()


def recovery_codes_match(secret_key: str, code: str, stored_hash: str) -> bool:
    computed = hash_recovery_code(secret_key, code)
    return hmac.compare_digest(computed, stored_hash)
