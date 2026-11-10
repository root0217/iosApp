"""Реалтайм-слой поверх REST-мессенджера из этапа 2. Один эндпоинт /ws: онлайн-доставка
сообщений, статусы «доставлено»/«прочитано» в реальном времени, «печатает…», presence.

Сессия БД держится только на время одной операции (а не на весь коннект) — соединение живёт
долго, а SQLAlchemy-сессию так надолго открытой лучше не держать."""
from __future__ import annotations

import json
import logging
import uuid

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from .. import db, presence
from ..deps import user_from_access_token
from ..models import User, utcnow
from . import service as svc
from .realtime import broadcast_new_message
from .router import _attachment_out  # переиспользуем ту же сборку вложения, что и REST-слой

log = logging.getLogger("app.messenger.ws")
router = APIRouter(tags=["messenger-ws"])


async def _authenticate(token: str | None) -> User | None:
    if not token:
        return None
    try:
        async with db.SessionLocal() as session:
            return await user_from_access_token(session, token)
    except Exception:
        return None


async def _broadcast_presence(user_id: uuid.UUID, username: str, online: bool, last_active_at) -> None:
    """Собеседникам рассылаем username, не user_id: по ТЗ обычным пользователям ID не показывается,
    а клиенту всё равно нечем было бы сверить голый id — у него на руках только username собеседника
    (PublicUserOut его тоже не отдаёт)."""
    async with db.SessionLocal() as session:
        partner_ids = await svc.conversation_partner_ids(session, user_id)
    payload = {"type": "presence", "username": username, "online": online,
              "last_active_at": last_active_at.isoformat() if last_active_at else None}
    for pid in partner_ids:
        await presence.manager.send_to_user(pid, payload)


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    token = websocket.query_params.get("token")
    user = await _authenticate(token)
    if user is None:
        await websocket.close(code=4401)
        return

    await websocket.accept()
    came_online = presence.manager.connect(user.id, websocket)
    async with db.SessionLocal() as session:
        db_user = await session.get(User, user.id)
        if db_user:
            db_user.last_active_at = utcnow()
            await session.commit()
    if came_online:
        await _broadcast_presence(user.id, user.username, True, utcnow())

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                event = json.loads(raw)
            except ValueError:
                continue
            await _handle_event(websocket, user, event)
    except WebSocketDisconnect:
        pass
    except Exception:
        log.exception("ошибка в цикле WebSocket для пользователя %s", user.id)
    finally:
        went_offline = presence.manager.disconnect(user.id, websocket)
        if went_offline:
            now = utcnow()
            async with db.SessionLocal() as session:
                db_user = await session.get(User, user.id)
                if db_user:
                    db_user.last_active_at = now
                    await session.commit()
            await _broadcast_presence(user.id, user.username, False, now)


async def _handle_event(websocket: WebSocket, user: User, event: dict) -> None:
    kind = event.get("type")

    if kind == "ping":
        await websocket.send_text(json.dumps({"type": "pong"}))
        return

    if kind == "typing":
        await _handle_typing(user, event)
        return

    if kind == "read":
        await _handle_read(user, event)
        return

    if kind == "message":
        await _handle_send_message(websocket, user, event)
        return
    # неизвестный тип — молча игнорируем, вперёд совместимость с будущими версиями клиента


async def _handle_typing(user: User, event: dict) -> None:
    conv_id = _as_uuid(event.get("conversation_id"))
    if conv_id is None:
        return
    async with db.SessionLocal() as session:
        try:
            conv, _member = await svc.get_membership(session, conv_id, user.id)
        except (svc.NotFound, svc.Forbidden):
            return
        other_id = conv.user_a_id if conv.user_b_id == user.id else conv.user_b_id
    await presence.manager.send_to_user(other_id, {"type": "typing", "conversation_id": str(conv_id), "user_id": str(user.id)})


async def _handle_read(user: User, event: dict) -> None:
    conv_id = _as_uuid(event.get("conversation_id"))
    msg_id = _as_uuid(event.get("up_to_message_id"))
    if conv_id is None or msg_id is None:
        return
    async with db.SessionLocal() as session:
        try:
            conv, _member = await svc.get_membership(session, conv_id, user.id)
            await svc.mark_read(session, conv, user.id, msg_id)
        except (svc.NotFound, svc.Forbidden):
            return
        await session.commit()
        other_id = conv.user_a_id if conv.user_b_id == user.id else conv.user_b_id
    await presence.manager.send_to_user(
        other_id, {"type": "read", "conversation_id": str(conv_id), "up_to_message_id": str(msg_id), "user_id": str(user.id)}
    )


async def _handle_send_message(websocket: WebSocket, user: User, event: dict) -> None:
    conv_id = _as_uuid(event.get("conversation_id"))
    if conv_id is None:
        return
    text = event.get("text")
    attachment_file_id = _as_uuid(event.get("attachment_file_id"))
    duration = event.get("attachment_duration_seconds")

    async with db.SessionLocal() as session:
        try:
            conv, _member = await svc.get_membership(session, conv_id, user.id)
            message = await svc.send_message(session, conv, user.id, text=text,
                                             attachment_file_id=attachment_file_id, attachment_duration=duration)
        except (svc.NotFound, svc.Forbidden, svc.Conflict) as e:
            await websocket.send_text(json.dumps({"type": "error", "code": getattr(e, "code", "rejected")}))
            return

        attachment = await _attachment_out(session, message)
        # отправитель прислал это по тому же сокету — исключаем его из рассылки своих же устройств,
        # у него сообщение и так уже есть локально
        await broadcast_new_message(session, conv, message, user.id, attachment, exclude_ws=websocket)


def _as_uuid(raw) -> uuid.UUID | None:
    if not raw:
        return None
    try:
        return uuid.UUID(str(raw))
    except ValueError:
        return None
