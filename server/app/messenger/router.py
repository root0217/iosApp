from __future__ import annotations

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy.ext.asyncio import AsyncSession

from ..deps import get_current_user, get_session
from ..models import User
from . import schemas as S
from . import service as svc
from .pure import delivery_state

router = APIRouter(prefix="/messenger", tags=["messenger"])


def _err(code: int, name: str, **extra) -> HTTPException:
    return HTTPException(code, detail={"code": name, **extra})


def _message_out(message, viewer_id: uuid.UUID, attachment_out: S.AttachmentOut | None) -> S.MessageOut:
    text = None if message.deleted_for_everyone_at else message.text
    return S.MessageOut(
        id=message.id, conversation_id=message.conversation_id, sender_id=message.sender_id,
        text=text, attachment=None if message.deleted_for_everyone_at else attachment_out,
        sent_at=message.sent_at, status=delivery_state(message.delivered_at, message.read_at),
        edited_at=message.edited_at, deleted_for_everyone=message.deleted_for_everyone_at is not None,
    )


async def _attachment_out(session: AsyncSession, message) -> S.AttachmentOut | None:
    if message.attachment_file_id is None or message.deleted_for_everyone_at is not None:
        return None
    from ..models import File
    f = await session.get(File, message.attachment_file_id)
    if f is None:
        return None
    return S.AttachmentOut(id=f.id, name=f.name, mime_type=f.mime_type, size_bytes=f.size_bytes,
                           duration_seconds=message.attachment_duration_seconds)


@router.get("/conversations", response_model=list[S.ConversationOut])
async def list_conversations(user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    rows = await svc.list_conversations(session, user.id)
    out = []
    for row in rows:
        last = row["last"]
        last_out = _message_out(last, user.id, await _attachment_out(session, last)) if last else None
        out.append(S.ConversationOut(
            id=row["conversation"].id,
            participant=S.PublicUserOut(username=row["other"].username,
                                        avatar_url=f"/v1/auth/users/{row['other'].id}/avatar" if row["other"].avatar_key else None),
            last_message=last_out, unread_count=row["unread"], pinned=row["member"].pinned,
            updated_at=row["conversation"].last_message_at,
        ))
    return out


@router.post("/conversations", response_model=S.ConversationOut, status_code=201)
async def start_conversation(body: S.StartConversationIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    try:
        conv = await svc.get_or_create_conversation(session, user.id, body.username)
    except svc.NotFound:
        raise _err(404, "user_not_found") from None
    except svc.Conflict as e:
        raise _err(409, e.code) from None
    await session.flush()
    _, member = await svc.get_membership(session, conv.id, user.id)
    other_id = conv.user_b_id if conv.user_a_id == user.id else conv.user_a_id
    other = await session.get(User, other_id)
    return S.ConversationOut(
        id=conv.id,
        participant=S.PublicUserOut(username=other.username, avatar_url=f"/v1/auth/users/{other.id}/avatar" if other.avatar_key else None),
        last_message=None, unread_count=0, pinned=member.pinned, updated_at=conv.last_message_at,
    )


@router.get("/conversations/{conversation_id}/messages", response_model=S.MessagesPage)
async def get_messages(conversation_id: uuid.UUID, before: datetime | None = None, limit: int = Query(50, ge=1, le=200),
                       user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    try:
        conv, _member = await svc.get_membership(session, conversation_id, user.id)
    except svc.NotFound:
        raise _err(404, "not_found") from None
    except svc.Forbidden:
        raise _err(403, "forbidden") from None
    messages, has_more = await svc.list_messages(session, conv, user.id, before, limit)
    out = [_message_out(m, user.id, await _attachment_out(session, m)) for m in messages]
    return S.MessagesPage(messages=out, has_more=has_more)


@router.post("/conversations/{conversation_id}/messages", response_model=S.MessageOut, status_code=201)
async def post_message(conversation_id: uuid.UUID, body: S.SendMessageIn,
                       user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    try:
        conv, _member = await svc.get_membership(session, conversation_id, user.id)
    except svc.NotFound:
        raise _err(404, "not_found") from None
    except svc.Forbidden:
        raise _err(403, "forbidden") from None
    try:
        message = await svc.send_message(session, conv, user.id, text=body.text,
                                         attachment_file_id=body.attachment_file_id,
                                         attachment_duration=body.attachment_duration_seconds)
    except svc.Forbidden:
        raise _err(403, "attachment_not_yours") from None
    except svc.Conflict as e:
        raise _err(409, e.code) from None
    return _message_out(message, user.id, await _attachment_out(session, message))


@router.patch("/messages/{message_id}", response_model=S.MessageOut)
async def edit_message(message_id: uuid.UUID, body: S.EditMessageIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    try:
        message = await svc.get_message_for_edit_or_delete(session, message_id, user.id)
        message = await svc.edit_message(session, message, user.id, body.text)
    except svc.NotFound:
        raise _err(404, "not_found") from None
    except svc.Forbidden:
        raise _err(403, "forbidden") from None
    except svc.Conflict as e:
        raise _err(409, e.code) from None
    return _message_out(message, user.id, await _attachment_out(session, message))


@router.delete("/messages/{message_id}", status_code=204, response_class=Response)
async def delete_message(message_id: uuid.UUID, for_everyone: bool = False,
                         user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    try:
        message = await svc.get_message_for_edit_or_delete(session, message_id, user.id)
        if for_everyone:
            storage_key = await svc.delete_message_for_everyone(session, message, user.id)
        else:
            storage_key = None
            await svc.delete_message_for_me(session, message, user.id)
    except svc.NotFound:
        raise _err(404, "not_found") from None
    except svc.Forbidden:
        raise _err(403, "forbidden") from None
    except svc.Conflict as e:
        raise _err(409, e.code) from None

    if storage_key:
        # сначала фиксируем удаление в БД, объект из хранилища убираем уже после коммита —
        # тот же порядок, что при purge в библиотеке
        await session.commit()
        from ..storage.registry import get_provider
        try:
            await get_provider(storage_key[0]).delete(storage_key[1])
        except Exception:
            pass  # осиротевший объект подберёт ночная сверка


@router.post("/conversations/{conversation_id}/read", status_code=204, response_class=Response)
async def mark_read(conversation_id: uuid.UUID, body: S.MarkReadIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    try:
        conv, _member = await svc.get_membership(session, conversation_id, user.id)
        await svc.mark_read(session, conv, user.id, body.up_to_message_id)
    except svc.NotFound:
        raise _err(404, "not_found") from None
    except svc.Forbidden:
        raise _err(403, "forbidden") from None


@router.patch("/conversations/{conversation_id}", status_code=204, response_class=Response)
async def pin_conversation(conversation_id: uuid.UUID, body: S.PinIn, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    try:
        _conv, member = await svc.get_membership(session, conversation_id, user.id)
    except svc.NotFound:
        raise _err(404, "not_found") from None
    except svc.Forbidden:
        raise _err(403, "forbidden") from None
    await svc.set_pinned(member, body.pinned)


@router.delete("/conversations/{conversation_id}", status_code=204, response_class=Response)
async def hide_conversation(conversation_id: uuid.UUID, user: User = Depends(get_current_user), session: AsyncSession = Depends(get_session)):
    """«Удалить» диалог у себя — он просто перестаёт попадать в /conversations, пока не придёт новое сообщение."""
    try:
        _conv, member = await svc.get_membership(session, conversation_id, user.id)
    except svc.NotFound:
        raise _err(404, "not_found") from None
    except svc.Forbidden:
        raise _err(403, "forbidden") from None
    await svc.hide_conversation(session, member)
