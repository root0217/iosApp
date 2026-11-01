from __future__ import annotations

import re
import secrets
import time
import uuid
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..deps import get_current_user, get_session
from ..models import RefreshToken, User, utcnow
from ..passwords import hash_password, verify_password
from ..security import create_token, hash_token, new_refresh_token

router = APIRouter(prefix="/auth", tags=["auth"])

_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# простейший ограничитель перебора пароля (в памяти процесса): 5 неудач за 15 минут на пару IP+email
_FAILS: dict[str, list[float]] = {}
_WINDOW, _MAX_FAILS = 15 * 60, 5


def _err(code: int, name: str, **extra) -> HTTPException:
    return HTTPException(code, detail={"code": name, **extra})


def _throttled(key: str) -> bool:
    now = time.time()
    hits = [t for t in _FAILS.get(key, []) if now - t < _WINDOW]
    _FAILS[key] = hits
    return len(hits) >= _MAX_FAILS


class RegisterIn(BaseModel):
    email: str
    password: str = Field(min_length=10, max_length=256)


class LoginIn(BaseModel):
    email: str
    password: str = Field(max_length=256)
    device_name: str | None = Field(default=None, max_length=100)


class RefreshIn(BaseModel):
    refresh_token: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class UserOut(BaseModel):
    id: uuid.UUID
    email: str


class SessionOut(BaseModel):
    id: uuid.UUID
    device_name: str | None
    created_at: datetime
    last_used_at: datetime | None


async def _issue(session: AsyncSession, user: User, device_name: str | None) -> TokenPair:
    s = get_settings()
    access_ttl = s.access_ttl_minutes * 60
    access = create_token(s.secret_key, sub=str(user.id), typ="access", ttl_seconds=access_ttl)
    refresh = new_refresh_token()
    session.add(
        RefreshToken(
            user_id=user.id,
            token_hash=hash_token(refresh),
            device_name=device_name,
            expires_at=utcnow() + timedelta(days=s.refresh_ttl_days),
        )
    )
    return TokenPair(access_token=access, refresh_token=refresh, expires_in=access_ttl)


@router.post("/register", response_model=UserOut, status_code=201)
async def register(body: RegisterIn, x_setup_token: str | None = Header(default=None), session: AsyncSession = Depends(get_session)):
    s = get_settings()
    if not s.setup_token or not x_setup_token or not secrets.compare_digest(x_setup_token, s.setup_token):
        raise _err(403, "registration_closed")
    email = body.email.strip().lower()
    if not _EMAIL.match(email):
        raise _err(422, "invalid_email")
    count = await session.scalar(select(func.count()).select_from(User))
    if count and not s.allow_registration:
        raise _err(403, "registration_closed")
    if await session.scalar(select(User.id).where(User.email == email)):
        raise _err(409, "email_taken")
    user = User(email=email, password_hash=hash_password(body.password))
    session.add(user)
    await session.flush()
    return UserOut(id=user.id, email=user.email)


@router.post("/login", response_model=TokenPair)
async def login(body: LoginIn, request: Request, session: AsyncSession = Depends(get_session)):
    email = body.email.strip().lower()
    ip = request.client.host if request.client else "unknown"
    key = f"{ip}|{email}"
    if _throttled(key):
        raise _err(429, "too_many_attempts")
    user = await session.scalar(select(User).where(User.email == email))
    ok = verify_password(user.password_hash if user else None, body.password)
    if not (ok and user and user.is_active):
        _FAILS.setdefault(key, []).append(time.time())
        raise _err(401, "invalid_credentials")
    _FAILS.pop(key, None)
    return await _issue(session, user, body.device_name)


@router.post("/refresh", response_model=TokenPair)
async def refresh(body: RefreshIn, session: AsyncSession = Depends(get_session)):
    row = await session.scalar(select(RefreshToken).where(RefreshToken.token_hash == hash_token(body.refresh_token)))
    if row is None:
        raise _err(401, "invalid_refresh_token")
    now = utcnow()
    if row.revoked_at is not None:
        # уже использованный токен предъявлен повторно: возможна кража, закрываем все сессии пользователя
        await session.execute(
            update(RefreshToken).where(RefreshToken.user_id == row.user_id, RefreshToken.revoked_at.is_(None)).values(revoked_at=now)
        )
        await session.commit()
        raise _err(401, "refresh_token_reused")
    if row.expires_at < now:
        raise _err(401, "refresh_token_expired")
    user = await session.get(User, row.user_id)
    if user is None or not user.is_active:
        raise _err(401, "invalid_refresh_token")
    row.revoked_at = now
    row.last_used_at = now
    return await _issue(session, user, row.device_name)


@router.post("/logout", status_code=204, response_class=Response)
async def logout(body: RefreshIn, session: AsyncSession = Depends(get_session)):
    row = await session.scalar(select(RefreshToken).where(RefreshToken.token_hash == hash_token(body.refresh_token)))
    if row and row.revoked_at is None:
        row.revoked_at = utcnow()


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)):
    return UserOut(id=user.id, email=user.email)


@router.get("/sessions", response_model=list[SessionOut])
async def sessions(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    rows = (
        await session.execute(
            select(RefreshToken)
            .where(RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None), RefreshToken.expires_at > utcnow())
            .order_by(RefreshToken.created_at.desc())
        )
    ).scalars()
    return [SessionOut(id=r.id, device_name=r.device_name, created_at=r.created_at, last_used_at=r.last_used_at) for r in rows]


@router.delete("/sessions/{session_id}", status_code=204, response_class=Response)
async def revoke_session(session_id: uuid.UUID, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    row = await session.get(RefreshToken, session_id)
    if row is None or row.user_id != user.id:
        raise _err(404, "not_found")
    if row.revoked_at is None:
        row.revoked_at = utcnow()
