from __future__ import annotations

import re
import secrets
import time
import uuid
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..deps import get_current_user, get_session
from ..models import File, Folder, PendingRegistration, RefreshToken, User, utcnow
from ..passwords import hash_password, verify_password
from ..security import create_token, hash_token, new_refresh_token
from ..storage.registry import default_provider, get_provider
from .avatars import InvalidImage, process_avatar
from .recovery import generate_recovery_code, hash_recovery_code, recovery_codes_match
from .reserved import RESERVED_USERNAMES
from .validators import normalize_username, password_error, username_error

router = APIRouter(prefix="/auth", tags=["auth"])

# --- защита от подбора пароля: в памяти процесса, по паре IP+username ---
# После login_max_attempts неудач — блокировка на login_lockout_minutes; если после разблокировки
# подбор продолжается, следующее окно вдвое длиннее (удваивается до потолка в 24 часа).
_FAILS: dict[str, tuple[int, float, int]] = {}  # key -> (fails, locked_until_ts, lockout_level)
_MAX_LOCKOUT_SECONDS = 24 * 3600


def _err(code: int, name: str, **extra) -> HTTPException:
    return HTTPException(code, detail={"code": name, **extra})


def _lock_check(key: str) -> None:
    fails, locked_until, _level = _FAILS.get(key, (0, 0.0, 0))
    if time.time() < locked_until:
        raise _err(429, "too_many_attempts", retry_after_seconds=int(locked_until - time.time()))


def _lock_record_failure(key: str) -> None:
    s = get_settings()
    fails, locked_until, level = _FAILS.get(key, (0, 0.0, 0))
    fails += 1
    if fails >= s.login_max_attempts:
        window = min(s.login_lockout_minutes * 60 * (2 ** level), _MAX_LOCKOUT_SECONDS)
        locked_until = time.time() + window
        level += 1
        fails = 0
    _FAILS[key] = (fails, locked_until, level)


def _lock_clear(key: str) -> None:
    _FAILS.pop(key, None)


async def _username_taken(session: AsyncSession, username: str, *, exclude_user: uuid.UUID | None = None) -> bool:
    q = select(User.id).where(User.username == username)
    if exclude_user is not None:
        q = q.where(User.id != exclude_user)
    if await session.scalar(q) is not None:
        return True
    pq = select(PendingRegistration.id).where(PendingRegistration.username == username, PendingRegistration.expires_at > utcnow())
    return await session.scalar(pq) is not None


def _avatar_url(user: User) -> str | None:
    return f"/v1/auth/users/{user.id}/avatar" if user.avatar_key else None


# ====================== схемы ======================
class UserOut(BaseModel):
    id: uuid.UUID
    username: str
    avatar_url: str | None = None
    is_admin: bool = False


class PublicUserOut(BaseModel):
    username: str
    avatar_url: str | None = None


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class RegisterStartIn(BaseModel):
    username: str = Field(min_length=3, max_length=30)
    password: str = Field(min_length=8, max_length=128)


class RegisterStartOut(BaseModel):
    pending_id: uuid.UUID
    recovery_code: str
    expires_in: int


class RegisterConfirmIn(BaseModel):
    pending_id: uuid.UUID
    recovery_code: str
    device_name: str | None = Field(default=None, max_length=100)


class LoginIn(BaseModel):
    username: str
    password: str = Field(max_length=256)
    device_name: str | None = Field(default=None, max_length=100)


class RefreshIn(BaseModel):
    refresh_token: str


class ChangePasswordIn(BaseModel):
    old_password: str = Field(max_length=256)
    new_password: str = Field(min_length=8, max_length=128)


class ChangeUsernameIn(BaseModel):
    username: str = Field(min_length=3, max_length=30)
    current_password: str = Field(max_length=256)


class RecoverPasswordIn(BaseModel):
    username: str
    recovery_code: str
    new_password: str = Field(min_length=8, max_length=128)


class RecoverUsernameIn(BaseModel):
    recovery_code: str


class RecoverUsernameOut(BaseModel):
    username: str


class DeleteAccountIn(BaseModel):
    password: str = Field(max_length=256)
    recovery_code: str


class AvailabilityOut(BaseModel):
    available: bool
    reason: str | None = None


class SessionOut(BaseModel):
    id: uuid.UUID
    device_name: str | None
    created_at: datetime
    last_used_at: datetime | None


# ====================== регистрация (открытая, в два шага) ======================
@router.get("/username-available", response_model=AvailabilityOut)
async def username_available(username: str = Query(min_length=1, max_length=30), session: AsyncSession = Depends(get_session)):
    normalized = normalize_username(username)
    err = username_error(normalized)
    if err:
        return AvailabilityOut(available=False, reason=err)
    taken = await _username_taken(session, normalized)
    return AvailabilityOut(available=not taken, reason="taken" if taken else None)


@router.post("/register/start", response_model=RegisterStartOut, status_code=201)
async def register_start(body: RegisterStartIn, session: AsyncSession = Depends(get_session)):
    username = normalize_username(body.username)
    if (err := username_error(username)) is not None:
        raise _err(422, "invalid_username", reason=err)
    if (err := password_error(body.password)) is not None:
        raise _err(422, "invalid_password", reason=err)
    if await _username_taken(session, username):
        raise _err(409, "username_taken")

    s = get_settings()
    code = generate_recovery_code()
    pending = PendingRegistration(
        username=username,
        password_hash=hash_password(body.password),
        recovery_code_hash=hash_recovery_code(s.secret_key, code),
        expires_at=utcnow() + timedelta(minutes=s.pending_registration_ttl_minutes),
    )
    session.add(pending)
    await session.flush()
    return RegisterStartOut(pending_id=pending.id, recovery_code=code, expires_in=s.pending_registration_ttl_minutes * 60)


async def _issue(session: AsyncSession, user: User, device_name: str | None) -> TokenPair:
    s = get_settings()
    access_ttl = s.access_ttl_minutes * 60
    access = create_token(s.secret_key, sub=str(user.id), typ="access", ttl_seconds=access_ttl)
    refresh = new_refresh_token()
    session.add(RefreshToken(user_id=user.id, token_hash=hash_token(refresh), device_name=device_name,
                             expires_at=utcnow() + timedelta(days=s.refresh_ttl_days)))
    return TokenPair(access_token=access, refresh_token=refresh, expires_in=access_ttl)


@router.post("/register/confirm", response_model=TokenPair)
async def register_confirm(body: RegisterConfirmIn, session: AsyncSession = Depends(get_session)):
    pending = await session.get(PendingRegistration, body.pending_id)
    if pending is None or pending.expires_at < utcnow():
        raise _err(410, "pending_expired")
    s = get_settings()
    if not recovery_codes_match(s.secret_key, body.recovery_code, pending.recovery_code_hash):
        raise _err(401, "invalid_recovery_code")
    if await _username_taken(session, pending.username):
        await session.delete(pending)
        raise _err(409, "username_taken")  # кто-то успел занять имя, пока код не ввели

    user = User(username=pending.username, password_hash=pending.password_hash, recovery_code_hash=pending.recovery_code_hash)
    session.add(user)
    await session.delete(pending)
    await session.flush()
    return await _issue(session, user, body.device_name)


# ====================== вход / токены ======================
@router.post("/login", response_model=TokenPair)
async def login(body: LoginIn, request: Request, session: AsyncSession = Depends(get_session)):
    username = normalize_username(body.username)
    ip = request.client.host if request.client else "unknown"
    key = f"{ip}|{username}"
    _lock_check(key)
    user = await session.scalar(select(User).where(User.username == username))
    ok = verify_password(user.password_hash if user else None, body.password)
    if not (ok and user and user.is_active):
        _lock_record_failure(key)
        raise _err(401, "invalid_credentials")
    _lock_clear(key)
    user.last_active_at = utcnow()
    return await _issue(session, user, body.device_name)


@router.post("/refresh", response_model=TokenPair)
async def refresh(body: RefreshIn, session: AsyncSession = Depends(get_session)):
    row = await session.scalar(select(RefreshToken).where(RefreshToken.token_hash == hash_token(body.refresh_token)))
    if row is None:
        raise _err(401, "invalid_refresh_token")
    now = utcnow()
    if row.revoked_at is not None:
        await session.execute(update(RefreshToken).where(RefreshToken.user_id == row.user_id, RefreshToken.revoked_at.is_(None)).values(revoked_at=now))
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


# ====================== профиль ======================
@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)):
    return UserOut(id=user.id, username=user.username, avatar_url=_avatar_url(user), is_admin=user.is_admin)


@router.patch("/me/username", response_model=UserOut)
async def change_username(body: ChangeUsernameIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    if not verify_password(user.password_hash, body.current_password):
        raise _err(401, "invalid_password")
    s = get_settings()
    if user.username_changed_at and utcnow() - user.username_changed_at < timedelta(days=7):
        next_at = user.username_changed_at + timedelta(days=7)
        raise _err(429, "username_change_too_soon", retry_after=next_at.isoformat())
    new_username = normalize_username(body.username)
    if new_username == user.username:
        return UserOut(id=user.id, username=user.username, avatar_url=_avatar_url(user), is_admin=user.is_admin)
    if (err := username_error(new_username)) is not None:
        raise _err(422, "invalid_username", reason=err)
    if await _username_taken(session, new_username, exclude_user=user.id):
        raise _err(409, "username_taken")
    user.username = new_username
    user.username_changed_at = utcnow()
    return UserOut(id=user.id, username=user.username, avatar_url=_avatar_url(user), is_admin=user.is_admin)


@router.post("/me/password", status_code=204, response_class=Response)
async def change_password(body: ChangePasswordIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    if not verify_password(user.password_hash, body.old_password):
        raise _err(401, "invalid_password")
    if (err := password_error(body.new_password)) is not None:
        raise _err(422, "invalid_password", reason=err)
    user.password_hash = hash_password(body.new_password)
    # все сессии кроме текущей — в сторону (у нас нет id текущего refresh-токена на этом эндпоинте,
    # так что текущий access остаётся рабочим до истечения, а остальные refresh-токены отзываются)
    await session.execute(update(RefreshToken).where(RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None)).values(revoked_at=utcnow()))


# ====================== восстановление ======================
@router.post("/recover/password", status_code=204, response_class=Response)
async def recover_password(body: RecoverPasswordIn, request: Request, session: AsyncSession = Depends(get_session)):
    username = normalize_username(body.username)
    ip = request.client.host if request.client else "unknown"
    key = f"recover|{ip}|{username}"
    _lock_check(key)
    user = await session.scalar(select(User).where(User.username == username))
    s = get_settings()
    ok = user is not None and recovery_codes_match(s.secret_key, body.recovery_code, user.recovery_code_hash)
    if not ok:
        _lock_record_failure(key)
        raise _err(401, "invalid_recovery_code")
    _lock_clear(key)
    if (err := password_error(body.new_password)) is not None:
        raise _err(422, "invalid_password", reason=err)
    user.password_hash = hash_password(body.new_password)
    await session.execute(update(RefreshToken).where(RefreshToken.user_id == user.id, RefreshToken.revoked_at.is_(None)).values(revoked_at=utcnow()))


@router.post("/recover/username", response_model=RecoverUsernameOut)
async def recover_username(body: RecoverUsernameIn, request: Request, session: AsyncSession = Depends(get_session)):
    ip = request.client.host if request.client else "unknown"
    key = f"recover-un|{ip}"
    _lock_check(key)
    s = get_settings()
    code_hash = hash_recovery_code(s.secret_key, body.recovery_code)
    user = await session.scalar(select(User).where(User.recovery_code_hash == code_hash))
    if user is None:
        _lock_record_failure(key)
        raise _err(401, "invalid_recovery_code")
    _lock_clear(key)
    return RecoverUsernameOut(username=user.username)


# ====================== удаление аккаунта ======================
@router.post("/me/delete", status_code=204, response_class=Response)
async def delete_account(body: DeleteAccountIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    s = get_settings()
    if not verify_password(user.password_hash, body.password):
        raise _err(401, "invalid_password")
    if not recovery_codes_match(s.secret_key, body.recovery_code, user.recovery_code_hash):
        raise _err(401, "invalid_recovery_code")

    keys: list[tuple[str, str]] = []
    if user.avatar_key:
        keys.append((s.default_storage, user.avatar_key))
    files = (await session.execute(select(File.storage_provider, File.storage_key).where(File.user_id == user.id))).all()
    keys += [(row.storage_provider, row.storage_key) for row in files]

    await session.delete(user)  # каскад удаляет Folder/File/RefreshToken по ondelete=CASCADE
    await session.commit()
    for provider_name, key in keys:
        try:
            await get_provider(provider_name).delete(key)
        except Exception:
            pass  # осиротевший объект без владельца подберёт ночная сверка


# ====================== поиск и чужие профили ======================
@router.get("/search", response_model=list[PublicUserOut])
async def search_users(q: str = Query(min_length=1, max_length=30), limit: int = Query(20, ge=1, le=50),
                       user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    needle = normalize_username(q).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    rows = (
        await session.execute(
            select(User)
            .where(User.id != user.id, User.is_active.is_(True), User.hidden_from_search.is_(False),
                  User.username.ilike(f"%{needle}%", escape="\\"))
            .order_by(User.username)
            .limit(limit)
        )
    ).scalars()
    return [PublicUserOut(username=u.username, avatar_url=_avatar_url(u)) for u in rows]


@router.get("/users/{username}", response_model=PublicUserOut)
async def get_public_profile(username: str, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    target = await session.scalar(select(User).where(User.username == normalize_username(username), User.is_active.is_(True)))
    if target is None:
        raise _err(404, "not_found")
    return PublicUserOut(username=target.username, avatar_url=_avatar_url(target))


# ====================== аватар ======================
@router.put("/me/avatar", response_model=UserOut)
async def upload_avatar(request: Request, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    s = get_settings()
    data = await request.body()
    if len(data) > s.avatar_max_source_bytes:
        raise _err(413, "too_large", max_bytes=s.avatar_max_source_bytes)
    try:
        jpeg = process_avatar(data, output_size=s.avatar_output_size)
    except InvalidImage as e:
        raise _err(422, "invalid_image", message=str(e)) from None

    storage = default_provider()
    key = storage.new_key()
    upload_id = uuid.uuid4().hex
    await storage.staging_begin(upload_id)
    await storage.staging_write(upload_id, 0, jpeg)
    obj = await storage.staging_commit(upload_id, key)

    old_key = user.avatar_key
    user.avatar_key = obj.key
    if old_key:
        try:
            await get_provider(s.default_storage).delete(old_key)
        except Exception:
            pass
    return UserOut(id=user.id, username=user.username, avatar_url=_avatar_url(user), is_admin=user.is_admin)


@router.delete("/me/avatar", status_code=204, response_class=Response)
async def delete_avatar(user: User = Depends(get_current_user)):
    if user.avatar_key:
        try:
            await default_provider().delete(user.avatar_key)
        except Exception:
            pass
        user.avatar_key = None


@router.get("/users/{user_id}/avatar")
async def get_avatar(user_id: uuid.UUID, session: AsyncSession = Depends(get_session)):
    from fastapi.responses import StreamingResponse

    target = await session.get(User, user_id)
    if target is None or not target.avatar_key:
        raise _err(404, "not_found")
    storage = get_provider(get_settings().default_storage)
    size = await storage.stat(target.avatar_key)
    return StreamingResponse(storage.iter_range(target.avatar_key, 0, size - 1), media_type="image/jpeg",
                             headers={"Cache-Control": "private, max-age=3600"})


# ====================== сессии ======================
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
