import uuid

import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from .config import get_settings
from .db import get_session
from .models import User
from .security import decode_token

_bearer = HTTPBearer(auto_error=False)


def unauthorized(code: str = "not_authenticated") -> HTTPException:
    return HTTPException(401, detail={"code": code}, headers={"WWW-Authenticate": "Bearer"})


async def user_from_access_token(session: AsyncSession, token: str) -> User:
    try:
        payload = decode_token(get_settings().secret_key, token, typ="access")
        user_id = uuid.UUID(payload["sub"])
    except (jwt.PyJWTError, ValueError, KeyError):
        raise unauthorized("invalid_token") from None
    user = await session.get(User, user_id)
    if user is None or not user.is_active:
        raise unauthorized("invalid_token")
    return user


async def get_current_user(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
    session: AsyncSession = Depends(get_session),
) -> User:
    if creds is None:
        raise unauthorized()
    return await user_from_access_token(session, creds.credentials)


__all__ = ["get_current_user", "get_session", "unauthorized", "user_from_access_token"]
