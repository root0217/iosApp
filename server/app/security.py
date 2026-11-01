"""Токены и хэширование токенов. Без зависимостей от БД и веб-фреймворка (удобно тестировать)."""
import hashlib
import secrets
import time
import uuid

import jwt

ALGO = "HS256"


def new_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def create_token(secret: str, *, sub: str, typ: str, ttl_seconds: int, **claims) -> str:
    now = int(time.time())
    payload = {"sub": sub, "typ": typ, "iat": now, "exp": now + ttl_seconds, "jti": uuid.uuid4().hex, **claims}
    return jwt.encode(payload, secret, algorithm=ALGO)


def decode_token(secret: str, token: str, *, typ: str) -> dict:
    payload = jwt.decode(token, secret, algorithms=[ALGO], options={"require": ["exp", "sub", "typ"]})
    if payload.get("typ") != typ:
        raise jwt.InvalidTokenError("wrong token type")
    return payload
