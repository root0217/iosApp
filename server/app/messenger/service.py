"""Бизнес-логика мессенджера поверх БД. HTTP-слой — в router.py."""
from __future__ import annotations

import uuid
from datetime import timedelta

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..auth.validators import normalize_username
from ..models import File, User, utcnow
from .models import Conversation, ConversationMember, Message, MessageHiddenFor
from .pure import canonical_pair, other_participant, within_edit_window

EDIT_WINDOW = timedelta(hours=48)


class NotFound(Exception):
    def __init__(self, what: str = "object"):
        super().__init__(what)
        self.what = what


class Forbidden(Exception):
    pass


class Conflict(Exception):
    def __init__(self, code: str, **extra):
        super().__init__(code)
        self.code = code
        self.extra = extra


async def get_or_create_conversation(session: AsyncSession, user_id: uuid.UUID, other_username: str) -> Conversation:
    target = await session.scalar(select(User).where(User.username == normalize_username(other_username), User.is_active.is_(True)))
    if target is None:
        raise NotFound("user")
    if target.id == user_id:
        raise Conflict("cannot_message_self")

    a, b = canonical_pair(user_id, target.id)
    conv = await session.scalar(select(Conversation).where(Conversation.user_a_id == a, Conversation.user_b_id == b))
    if conv is not None:
        return conv

    conv = Conversation(user_a_id=a, user_b_id=b)
    session.add(conv)
    await session.flush()
    session.add_all([
        ConversationMember(conversation_id=conv.id, user_id=a),
        ConversationMember(conversation_id=conv.id, user_id=b),
    ])
    return conv


async def get_membership(session: AsyncSession, conversation_id: uuid.UUID, user_id: uuid.UUID) -> tuple[Conversation, ConversationMember]:
    conv = await session.get(Conversation, conversation_id)
    if conv is None:
        raise NotFound("conversation")
    member = await session.get(ConversationMember, {"conversation_id": conversation_id, "user_id": user_id})
    if member is None:
        raise Forbidden()
    return conv, member


async def list_conversations(session: AsyncSession, user_id: uuid.UUID) -> list[dict]:
    memberships = (
        await session.execute(
            select(ConversationMember, Conversation)
            .join(Conversation, Conversation.id == ConversationMember.conversation_id)
            .where(ConversationMember.user_id == user_id, ConversationMember.hidden_at.is_(None))
            .order_by(Conversation.last_message_at.desc())
        )
    ).all()

    out = []
    for member, conv in memberships:
        other_id = other_participant(conv.user_a_id, conv.user_b_id, user_id)
        other = await session.get(User, other_id)
        if other is None:
            continue
        last = (
            await session.execute(
                select(Message)
                .where(Message.conversation_id == conv.id, Message.deleted_for_everyone_at.is_(None))
                .where(~Message.id.in_(select(MessageHiddenFor.message_id).where(MessageHiddenFor.user_id == user_id)))
                .order_by(Message.sent_at.desc())
                .limit(1)
            )
        ).scalar_one_or_none()
        unread = await session.scalar(
            select(func.count()).select_from(Message).where(
                Message.conversation_id == conv.id, Message.sender_id != user_id, Message.read_at.is_(None),
                Message.deleted_for_everyone_at.is_(None),
            )
        )
        out.append({"conversation": conv, "member": member, "other": other, "last": last, "unread": unread or 0})
    return out


async def list_messages(session: AsyncSession, conv: Conversation, viewer_id: uuid.UUID, before, limit: int) -> tuple[list[Message], bool]:
    q = (
        select(Message)
        .where(Message.conversation_id == conv.id)
        .where(~Message.id.in_(select(MessageHiddenFor.message_id).where(MessageHiddenFor.user_id == viewer_id)))
        .order_by(Message.sent_at.desc())
        .limit(limit + 1)
    )
    if before is not None:
        q = q.where(Message.sent_at < before)
    rows = (await session.execute(q)).scalars().all()
    has_more = len(rows) > limit
    rows = rows[:limit]

    # получатель увидел список — для всех чужих сообщений без delivered_at простановка «доставлено»
    to_mark = [m for m in rows if m.sender_id != viewer_id and m.delivered_at is None]
    now = utcnow()
    for m in to_mark:
        m.delivered_at = now
    return list(reversed(rows)), has_more


async def send_message(
    session: AsyncSession, conv: Conversation, sender_id: uuid.UUID, *,
    text: str | None, attachment_file_id: uuid.UUID | None, attachment_duration: float | None,
) -> Message:
    text = text.strip() if text else None
    if not text and attachment_file_id is None:
        raise Conflict("empty_message")

    if attachment_file_id is not None:
        att = await session.get(File, attachment_file_id)
        if att is None or att.user_id != sender_id or not att.is_message_attachment:
            raise Forbidden()
        already_used = await session.scalar(select(Message.id).where(Message.attachment_file_id == attachment_file_id))
        if already_used is not None:
            raise Conflict("attachment_already_used")

    message = Message(
        conversation_id=conv.id, sender_id=sender_id, text=text,
        attachment_file_id=attachment_file_id, attachment_duration_seconds=attachment_duration,
    )
    session.add(message)
    conv.last_message_at = utcnow()

    # новое сообщение «оживляет» диалог, даже если кто-то (в т.ч. сам отправитель) удалял его у себя
    members = (await session.execute(select(ConversationMember).where(ConversationMember.conversation_id == conv.id))).scalars()
    for m in members:
        m.hidden_at = None
    await session.flush()
    return message


async def get_message_for_edit_or_delete(session: AsyncSession, message_id: uuid.UUID, user_id: uuid.UUID) -> Message:
    msg = await session.get(Message, message_id)
    if msg is None:
        raise NotFound("message")
    await get_membership(session, msg.conversation_id, user_id)  # бросит Forbidden, если не участник
    return msg


async def edit_message(session: AsyncSession, message: Message, editor_id: uuid.UUID, text: str) -> Message:
    if message.sender_id != editor_id:
        raise Forbidden()
    if message.deleted_for_everyone_at is not None:
        raise Conflict("message_deleted")
    if message.attachment_file_id is not None:
        raise Conflict("cannot_edit_attachment")
    if not within_edit_window(message.sent_at, utcnow(), EDIT_WINDOW):
        raise Conflict("edit_window_expired")
    message.text = text.strip()
    message.edited_at = utcnow()
    return message


async def delete_message_for_me(session: AsyncSession, message: Message, user_id: uuid.UUID) -> None:
    exists = await session.get(MessageHiddenFor, {"message_id": message.id, "user_id": user_id})
    if exists is None:
        session.add(MessageHiddenFor(message_id=message.id, user_id=user_id))


async def delete_message_for_everyone(session: AsyncSession, message: Message, user_id: uuid.UUID) -> tuple[str, str] | None:
    """Возвращает (provider, key) вложения, если оно было — вызывающий код обязан удалить сам объект
    из хранилища ПОСЛЕ коммита (тот же паттерн отложенного удаления, что и в library/router.py)."""
    if message.sender_id != user_id:
        raise Forbidden()
    if not within_edit_window(message.sent_at, utcnow(), EDIT_WINDOW):
        raise Conflict("delete_window_expired")

    storage_key: tuple[str, str] | None = None
    if message.attachment_file_id is not None:
        att = await session.get(File, message.attachment_file_id)
        if att is not None:
            storage_key = (att.storage_provider, att.storage_key)
            await session.delete(att)

    message.deleted_for_everyone_at = utcnow()
    message.text = None
    message.attachment_file_id = None
    return storage_key


async def mark_read(session: AsyncSession, conv: Conversation, viewer_id: uuid.UUID, up_to_message_id: uuid.UUID) -> None:
    up_to = await session.get(Message, up_to_message_id)
    if up_to is None or up_to.conversation_id != conv.id:
        raise NotFound("message")
    now = utcnow()
    rows = (
        await session.execute(
            select(Message).where(
                Message.conversation_id == conv.id, Message.sender_id != viewer_id,
                Message.sent_at <= up_to.sent_at, Message.read_at.is_(None),
            )
        )
    ).scalars()
    for m in rows:
        m.read_at = now
        if m.delivered_at is None:
            m.delivered_at = now


async def set_pinned(member: ConversationMember, pinned: bool) -> None:
    member.pinned = pinned


async def hide_conversation(session: AsyncSession, member: ConversationMember) -> None:
    member.hidden_at = utcnow()
