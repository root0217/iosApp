"""Общая точка для WS-рассылки нового сообщения — используется и REST-эндпоинтом отправки
(app/messenger/router.py), и обработчиком события "message" в WebSocket (ws_router.py), чтобы
получатель узнавал о сообщении мгновенно независимо от того, каким путём его отправили."""
from __future__ import annotations

import json
import uuid

from fastapi import WebSocket
from sqlalchemy.ext.asyncio import AsyncSession

from .. import presence
from . import schemas as S
from . import service as svc
from .models import Conversation, Message
from .pure import delivery_state


def _message_payload(message: Message, attachment: S.AttachmentOut | None) -> dict:
    out = S.MessageOut(
        id=message.id, conversation_id=message.conversation_id, sender_id=message.sender_id,
        text=None if message.deleted_for_everyone_at else message.text,
        attachment=None if message.deleted_for_everyone_at else attachment,
        sent_at=message.sent_at, status=delivery_state(message.delivered_at, message.read_at),
        edited_at=message.edited_at, deleted_for_everyone=message.deleted_for_everyone_at is not None,
    )
    return {"type": "message", "message": json.loads(out.model_dump_json())}


async def broadcast_new_message(
    session: AsyncSession, conv: Conversation, message: Message, sender_id: uuid.UUID,
    attachment: S.AttachmentOut | None, *, exclude_ws: WebSocket | None = None,
) -> None:
    """Отмечает «доставлено», если получатель сейчас онлайн, коммитит это, и рассылает сообщение
    обеим сторонам: получателю (если он на связи) и остальным устройствам самого отправителя."""
    other_id = conv.user_a_id if conv.user_b_id == sender_id else conv.user_b_id
    delivered_now = presence.manager.is_online(other_id)
    if delivered_now:
        await svc.mark_delivered_now(session, message)
    await session.commit()

    payload = _message_payload(message, attachment)
    await presence.manager.send_to_user(other_id, payload)
    await presence.manager.send_to_user(sender_id, payload, exclude=exclude_ws)
    if delivered_now:
        await presence.manager.send_to_user(sender_id, {"type": "message_status", "message_id": str(message.id), "status": "delivered"})
