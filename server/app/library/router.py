from __future__ import annotations

import logging
import mimetypes
import uuid
from datetime import timedelta
from typing import Literal
from urllib.parse import quote

import jwt
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import StreamingResponse
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import get_settings
from ..deps import get_current_user, get_session, unauthorized, user_from_access_token
from ..models import File, Folder, UploadSession, User, utcnow
from ..names import safe_name, split_ext
from ..security import create_token, decode_token
from ..storage.base import ObjectNotFound, OffsetMismatch, StorageError
from ..storage.registry import default_provider, get_provider
from . import schemas as S
from . import service as svc
from .ranges import RangeNotSatisfiable, parse_range
from .zipstream import ZipEntry, stream_zip

log = logging.getLogger("app.library")
router = APIRouter(prefix="/library", tags=["library"])

INLINE_TYPES = ("image/", "audio/", "video/", "text/plain", "application/pdf")
NEVER_INLINE = ("image/svg+xml", "text/html")  # могут исполнять скрипты


def _http(code: int, name: str, **extra) -> HTTPException:
    return HTTPException(code, detail={"code": name, **extra})


def _parse_folder_id(raw: str) -> uuid.UUID | None:
    if raw == "root":
        return None
    try:
        return uuid.UUID(raw)
    except ValueError:
        raise _http(422, "invalid_folder_id") from None


def _check_if_match(request: Request, current: int) -> None:
    raw = request.headers.get("if-match")
    if raw is None:
        return
    try:
        wanted = int(raw.strip('"'))
    except ValueError:
        raise _http(400, "invalid_if_match") from None
    if wanted != current:
        raise _http(409, "version_conflict", current_version=current)


async def _delete_objects(keys: list[tuple[str, str]]) -> None:
    for provider_name, key in keys:
        try:
            await get_provider(provider_name).delete(key)
        except Exception:
            log.exception("не удалось удалить объект %s/%s (его уберёт ночная сверка)", provider_name, key)


# ====================== просмотр и папки ======================
@router.get("/folders/{folder_id}", response_model=S.ListingOut)
async def list_folder(
    folder_id: str,
    sort: Literal["name", "updated", "size"] = "name",
    order: Literal["asc", "desc"] = "asc",
    user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
):
    fid = _parse_folder_id(folder_id)
    folder = crumbs = None
    if fid is not None:
        folder = await svc.get_folder(session, user.id, fid)
        crumbs = await svc.breadcrumbs(session, user.id, folder)

    fq = select(Folder).where(Folder.user_id == user.id, Folder.deleted_at.is_(None), Folder.parent_id.is_(None) if fid is None else Folder.parent_id == fid)
    fl = select(File).where(File.user_id == user.id, File.deleted_at.is_(None), File.folder_id.is_(None) if fid is None else File.folder_id == fid)
    key_f = {"name": func.lower(Folder.name), "updated": Folder.updated_at, "size": func.lower(Folder.name)}[sort]
    key_l = {"name": func.lower(File.name), "updated": File.updated_at, "size": File.size_bytes}[sort]
    fq = fq.order_by(key_f.desc() if order == "desc" else key_f.asc())
    fl = fl.order_by(key_l.desc() if order == "desc" else key_l.asc())
    folders = (await session.execute(fq)).scalars().all()
    files = (await session.execute(fl)).scalars().all()
    return S.ListingOut(
        folder=folder,
        breadcrumbs=[S.Breadcrumb(id=c.id, name=c.name) for c in (crumbs or [])],
        folders=folders,
        files=files,
    )


@router.post("/folders", response_model=S.FolderOut, status_code=201)
async def create_folder(body: S.FolderCreate, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    name = safe_name(body.name)
    if body.parent_id is not None:
        await svc.get_folder(session, user.id, body.parent_id)
    await svc.ensure_free(session, user.id, body.parent_id, name)
    folder = Folder(user_id=user.id, parent_id=body.parent_id, name=name)
    session.add(folder)
    await session.flush()
    await svc.record(session, user.id, "folder", [folder.id], "upsert")
    return folder


@router.patch("/folders/{folder_id}", response_model=S.FolderOut)
async def patch_folder(folder_id: uuid.UUID, body: S.FolderPatch, request: Request, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    folder = await svc.get_folder(session, user.id, folder_id)
    _check_if_match(request, folder.version)
    new_parent = folder.parent_id
    if "parent_id" in body.model_fields_set:
        new_parent = body.parent_id
        if new_parent is not None:
            await svc.get_folder(session, user.id, new_parent)
            if new_parent == folder.id or new_parent in await svc.subtree_folder_ids(session, user.id, folder.id):
                raise _http(409, "cycle", message="нельзя переместить папку внутрь самой себя")
    new_name = safe_name(body.name) if body.name is not None else folder.name
    if new_parent != folder.parent_id or new_name != folder.name:
        await svc.ensure_free(session, user.id, new_parent, new_name, exclude_folder=folder.id)
    folder.parent_id, folder.name = new_parent, new_name
    folder.version += 1
    folder.updated_at = utcnow()
    await svc.record(session, user.id, "folder", [folder.id], "upsert")
    return folder


@router.delete("/folders/{folder_id}", status_code=204, response_class=Response)
async def delete_folder(folder_id: uuid.UUID, request: Request, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    folder = await svc.get_folder(session, user.id, folder_id)
    _check_if_match(request, folder.version)
    await svc.trash_folder(session, user.id, folder)


# ====================== файлы ======================
@router.get("/files/{file_id}", response_model=S.FileOut)
async def get_file_meta(file_id: uuid.UUID, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    return await svc.get_file(session, user.id, file_id)


@router.patch("/files/{file_id}", response_model=S.FileOut)
async def patch_file(file_id: uuid.UUID, body: S.FilePatch, request: Request, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    f = await svc.get_file(session, user.id, file_id)
    _check_if_match(request, f.version)
    new_folder = f.folder_id
    if "folder_id" in body.model_fields_set:
        new_folder = body.folder_id
        if new_folder is not None:
            await svc.get_folder(session, user.id, new_folder)
    new_name = safe_name(body.name) if body.name is not None else f.name
    if new_folder != f.folder_id or new_name != f.name:
        await svc.ensure_free(session, user.id, new_folder, new_name, exclude_file=f.id)
    f.folder_id, f.name = new_folder, new_name
    f.extension = split_ext(new_name)[1].lower()
    if body.meta is not None:
        f.meta = {**(f.meta or {}), **body.meta}
    f.version += 1
    f.updated_at = utcnow()
    await svc.record(session, user.id, "file", [f.id], "upsert")
    return f


@router.delete("/files/{file_id}", status_code=204, response_class=Response)
async def delete_file(file_id: uuid.UUID, request: Request, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    f = await svc.get_file(session, user.id, file_id)
    _check_if_match(request, f.version)
    await svc.trash_file(session, user.id, f)


@router.post("/bulk/delete", response_model=S.BulkResult)
async def bulk_delete(body: S.IdsIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    missing: list[uuid.UUID] = []
    nf = nd = 0
    for fid in body.file_ids:
        try:
            await svc.trash_file(session, user.id, await svc.get_file(session, user.id, fid))
            nf += 1
        except svc.NotFound:
            missing.append(fid)
    for did in body.folder_ids:
        try:
            await svc.trash_folder(session, user.id, await svc.get_folder(session, user.id, did))
            nd += 1
        except svc.NotFound:
            missing.append(did)
    return S.BulkResult(files=nf, folders=nd, not_found=missing)


# ====================== загрузка с докачкой ======================
def _upload_out(up: UploadSession) -> S.UploadOut:
    return S.UploadOut(id=up.id, name=up.name, size=up.size_bytes, received=up.received_bytes, folder_id=up.folder_id, expires_at=up.expires_at)


async def _get_upload(session: AsyncSession, user_id: uuid.UUID, upload_id: uuid.UUID) -> UploadSession:
    up = await session.get(UploadSession, upload_id)
    if up is None or up.user_id != user_id:
        raise _http(404, "upload_not_found")
    return up


@router.post("/uploads", response_model=S.UploadOut, status_code=201)
async def create_upload(body: S.UploadCreate, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    s = get_settings()
    if body.size > s.max_upload_bytes:
        raise _http(413, "too_large", max_bytes=s.max_upload_bytes)
    name = safe_name(body.name)
    if body.folder_id is not None:
        await svc.get_folder(session, user.id, body.folder_id)
    up = UploadSession(
        user_id=user.id,
        folder_id=body.folder_id,
        name=name,
        mime_type=body.mime_type,
        size_bytes=body.size,
        received_bytes=0,
        expires_at=utcnow() + timedelta(hours=s.upload_session_ttl_hours),
    )
    session.add(up)
    await session.flush()
    await default_provider().staging_begin(str(up.id))
    return _upload_out(up)


@router.get("/uploads", response_model=list[S.UploadOut])
async def list_uploads(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    rows = (await session.execute(select(UploadSession).where(UploadSession.user_id == user.id).order_by(UploadSession.created_at))).scalars()
    return [_upload_out(u) for u in rows]


@router.get("/uploads/{upload_id}", response_model=S.UploadOut)
async def upload_status(upload_id: uuid.UUID, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    return _upload_out(await _get_upload(session, user.id, upload_id))


@router.put("/uploads/{upload_id}", response_model=S.UploadOut)
async def put_chunk(upload_id: uuid.UUID, offset: int, request: Request, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    """Тело запроса: сырые байты куска (Content-Type: application/octet-stream). offset должен совпадать с received."""
    up = await _get_upload(session, user.id, upload_id)
    if offset != up.received_bytes:
        raise _http(409, "offset_mismatch", expected_offset=up.received_bytes)
    storage = default_provider()
    try:
        await storage.staging_truncate(str(up.id), offset)  # отрезаем хвост оборванного прошлого запроса
        pos = offset
        async for data in request.stream():
            if not data:
                continue
            if pos + len(data) > up.size_bytes:
                raise _http(413, "exceeds_declared_size", size=up.size_bytes)
            pos = await storage.staging_write(str(up.id), pos, data)
    except OffsetMismatch as e:
        raise _http(409, "offset_mismatch", expected_offset=e.expected) from None
    except ObjectNotFound:
        raise _http(404, "upload_not_found") from None
    up.received_bytes = pos
    return _upload_out(up)


@router.delete("/uploads/{upload_id}", status_code=204, response_class=Response)
async def abort_upload(upload_id: uuid.UUID, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    up = await _get_upload(session, user.id, upload_id)
    await default_provider().staging_abort(str(up.id))
    await session.delete(up)


@router.post("/uploads/{upload_id}/complete", response_model=S.CompleteOut)
async def complete_upload(upload_id: uuid.UUID, body: S.CompleteIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    up = await _get_upload(session, user.id, upload_id)
    storage = default_provider()
    if up.received_bytes != up.size_bytes:
        raise _http(409, "incomplete", received=up.received_bytes, size=up.size_bytes)
    try:
        actual = await storage.staging_size(str(up.id))
    except ObjectNotFound:
        raise _http(410, "upload_lost", message="черновик пропал с сервера, загрузите файл заново") from None
    if actual != up.size_bytes:
        await storage.staging_truncate(str(up.id), min(actual, up.received_bytes))
        raise _http(409, "incomplete", received=min(actual, up.received_bytes), size=up.size_bytes)

    # имя и конфликты решаем ДО фиксации файла в хранилище
    name = up.name
    existing: File | None = None
    taken = await svc.live_names(session, user.id, up.folder_id)
    if name.lower() in taken:
        if body.on_conflict == "fail":
            raise _http(409, "name_conflict", name=name)
        if body.on_conflict == "replace":
            existing = (
                await session.execute(
                    select(File).where(File.user_id == user.id, File.deleted_at.is_(None), func.lower(File.name) == name.lower(),
                                       File.folder_id.is_(None) if up.folder_id is None else File.folder_id == up.folder_id)
                )
            ).scalar_one_or_none()
            if existing is None:  # занято папкой: заменить нельзя
                raise _http(409, "name_conflict", name=name)
        else:
            from ..names import unique_name
            name = unique_name(name, taken)

    key = storage.new_key()
    obj = await storage.staging_commit(str(up.id), key)
    if body.sha256 and body.sha256.lower() != obj.sha256:
        await storage.delete(key)
        await session.delete(up)
        await session.commit()
        raise _http(422, "checksum_mismatch", message="контрольная сумма не совпала, загрузите файл заново")

    dup = await session.scalar(
        select(File.id).where(File.user_id == user.id, File.deleted_at.is_(None), File.sha256 == obj.sha256, File.size_bytes == obj.size).limit(1)
    )
    mime = up.mime_type or mimetypes.guess_type(name)[0] or "application/octet-stream"
    old_key = None
    if existing is not None:
        old_key = (existing.storage_provider, existing.storage_key)
        existing.storage_provider, existing.storage_key = storage.name, key
        existing.size_bytes, existing.sha256, existing.mime_type = obj.size, obj.sha256, mime
        existing.version += 1
        existing.updated_at = utcnow()
        f, replaced = existing, True
    else:
        f = File(
            user_id=user.id, folder_id=up.folder_id, name=name, original_name=up.name,
            extension=split_ext(name)[1].lower(), mime_type=mime, size_bytes=obj.size, sha256=obj.sha256,
            storage_provider=storage.name, storage_key=key, meta={},
        )
        session.add(f)
        replaced = False
    await session.delete(up)
    await session.flush()
    await svc.record(session, user.id, "file", [f.id], "upsert")
    await session.commit()
    if old_key:
        await _delete_objects([old_key])
    return S.CompleteOut(file=f, duplicate_of=dup if dup != f.id else None, replaced=replaced)


# ====================== скачивание ======================
def _content_disposition(name: str, mime: str, force_download: bool) -> str:
    inline = (not force_download) and mime.startswith(INLINE_TYPES) and mime not in NEVER_INLINE
    ascii_name = name.encode("ascii", "ignore").decode().replace('"', "") or "file"
    return f"{'inline' if inline else 'attachment'}; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name)}", inline


@router.post("/files/{file_id}/link", response_model=S.LinkOut)
async def make_link(file_id: uuid.UUID, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    """Короткоживущая ссылка на файл (для плеера и предпросмотра, где нельзя добавить заголовок Authorization)."""
    await svc.get_file(session, user.id, file_id)
    s = get_settings()
    token = create_token(s.secret_key, sub=str(user.id), typ="dl", ttl_seconds=s.download_link_ttl_seconds, file=str(file_id))
    return S.LinkOut(url=f"/v1/library/files/{file_id}/content?t={token}", expires_in=s.download_link_ttl_seconds)


async def _content_user(request: Request, session: AsyncSession, file_id: uuid.UUID, t: str | None) -> uuid.UUID:
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return (await user_from_access_token(session, auth[7:].strip())).id
    if t:
        try:
            payload = decode_token(get_settings().secret_key, t, typ="dl")
            if payload.get("file") != str(file_id):
                raise jwt.InvalidTokenError("wrong file")
            return uuid.UUID(payload["sub"])
        except (jwt.PyJWTError, ValueError, KeyError):
            raise unauthorized("invalid_link") from None
    raise unauthorized()


@router.api_route("/files/{file_id}/content", methods=["GET", "HEAD"])
async def file_content(file_id: uuid.UUID, request: Request, download: bool = False, t: str | None = None, session: AsyncSession = Depends(get_session)):
    user_id = await _content_user(request, session, file_id, t)
    f = await svc.get_file(session, user_id, file_id)
    name, mime, size, sha, prov, key = f.name, f.mime_type, f.size_bytes, f.sha256, f.storage_provider, f.storage_key
    storage = get_provider(prov)
    try:
        rng = parse_range(request.headers.get("range"), size)
    except RangeNotSatisfiable:
        return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
    start, end = rng if rng else (0, size - 1)
    disposition, inline = _content_disposition(name, mime, download)
    headers = {
        "Accept-Ranges": "bytes", "ETag": f'"{sha}"', "Content-Disposition": disposition,
        "Content-Length": str(max(end - start + 1, 0)), "X-Content-Type-Options": "nosniff",
    }
    if inline:
        headers["Content-Security-Policy"] = "sandbox"
    if rng:
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"
    status = 206 if rng else 200
    if request.method == "HEAD" or size == 0:
        return Response(status_code=status, headers=headers, media_type=mime)
    return StreamingResponse(storage.iter_range(key, start, end), status_code=status, headers=headers, media_type=mime)


@router.post("/zip")
async def download_zip(body: S.ZipIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    if not body.file_ids and not body.folder_ids:
        raise _http(422, "nothing_selected")
    raw = await svc.collect_zip_entries(session, user.id, body.file_ids, body.folder_ids)
    entries = []
    for arcname, is_dir, mtime, prov, key in raw:
        dt = (mtime.year, mtime.month, mtime.day, mtime.hour, mtime.minute, mtime.second)
        if is_dir:
            entries.append(ZipEntry(arcname, dt, None))
        else:
            storage = get_provider(prov)

            def make(storage=storage, key=key):
                async def gen():
                    size = await storage.stat(key)
                    if size:
                        async for chunk in storage.iter_range(key, 0, size - 1):
                            yield chunk
                return gen

            entries.append(ZipEntry(arcname, dt, make()))
    filename = safe_name(body.name or "archive") + ".zip"
    return StreamingResponse(
        stream_zip(entries), media_type="application/zip",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename)}", "X-Content-Type-Options": "nosniff"},
    )


# ====================== использование хранилища ======================
@router.get("/usage", response_model=S.UsageOut)
async def usage(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    """Минимальное добавление под ТЗ библиотеки: сервер не считал занятое место, клиенту показывать было нечего."""
    total = await session.scalar(
        select(func.coalesce(func.sum(File.size_bytes), 0)).where(File.user_id == user.id, File.deleted_at.is_(None))
    )
    return S.UsageOut(used_bytes=int(total or 0))


# ====================== корзина ======================
@router.get("/trash", response_model=S.TrashOut)
async def list_trash(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    files = (await session.execute(select(File).where(File.user_id == user.id, File.deleted_at.is_not(None), File.deleted_via.is_(None)).order_by(File.deleted_at.desc()))).scalars().all()
    folders = (await session.execute(select(Folder).where(Folder.user_id == user.id, Folder.deleted_at.is_not(None), Folder.deleted_via.is_(None)).order_by(Folder.deleted_at.desc()))).scalars().all()
    return S.TrashOut(files=files, folders=folders)


@router.post("/trash/restore", response_model=S.BulkResult)
async def restore(body: S.IdsIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    missing: list[uuid.UUID] = []
    nf = nd = 0
    for fid in body.file_ids:
        try:
            f = await svc.get_file(session, user.id, fid, deleted=True)
            await svc.restore_file(session, user.id, f)
            nf += 1
        except svc.NotFound:
            missing.append(fid)
    for did in body.folder_ids:
        try:
            fo = await svc.get_folder(session, user.id, did, deleted=True)
            await svc.restore_folder(session, user.id, fo)
            nd += 1
        except svc.NotFound:
            missing.append(did)
    return S.BulkResult(files=nf, folders=nd, not_found=missing)


@router.post("/trash/purge", response_model=S.BulkResult)
async def purge(body: S.IdsIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    """Безвозвратное удаление из корзины (файлы физически удаляются с сервера). Клиент обязан запросить подтверждение."""
    missing: list[uuid.UUID] = []
    keys: list[tuple[str, str]] = []
    nf = nd = 0
    for fid in body.file_ids:
        try:
            keys += await svc.purge_file(session, await svc.get_file(session, user.id, fid, deleted=True))
            nf += 1
        except svc.NotFound:
            missing.append(fid)
    for did in body.folder_ids:
        try:
            keys += await svc.purge_folder(session, user.id, await svc.get_folder(session, user.id, did, deleted=True))
            nd += 1
        except svc.NotFound:
            missing.append(did)
    await session.commit()
    await _delete_objects(keys)
    return S.BulkResult(files=nf, folders=nd, not_found=missing)


# ====================== синхронизация ======================
@router.get("/changes", response_model=S.ChangesOut)
async def changes(cursor: int = 0, limit: int = 500, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    limit = max(1, min(limit, 1000))
    rows, new_cursor, has_more = await svc.changes_since(session, user.id, cursor, limit)
    out = [S.ChangeOut(seq=r.seq, entity_type=r.entity_type, entity_id=r.entity_id, op=op, file=file, folder=folder) for r, op, file, folder in rows]
    return S.ChangesOut(changes=out, cursor=new_cursor, has_more=has_more)
