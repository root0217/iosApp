"""Кто сейчас онлайн — в памяти процесса, не в БД. «Был(а) недавно» хранится в БД
(users.last_active_at), «в сети» — это просто «есть хотя бы одно открытое соединение».

Сознательное ограничение: работает только с одним процессом uvicorn (так сейчас и
запущено — Dockerfile не задаёт --workers). При нескольких воркерах/репликах сюда
понадобится что-то вроде Redis pub/sub, чтобы воркеры видели соединения друг друга."""
from __future__ import annotations

import json
import uuid
from typing import Any

from fastapi import WebSocket


class ConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[uuid.UUID, set[WebSocket]] = {}

    def connect(self, user_id: uuid.UUID, ws: WebSocket) -> bool:
        """True, если это первое соединение пользователя (переход offline → online)."""
        first = user_id not in self._connections or not self._connections[user_id]
        self._connections.setdefault(user_id, set()).add(ws)
        return first

    def disconnect(self, user_id: uuid.UUID, ws: WebSocket) -> bool:
        """True, если после отключения соединений у пользователя не осталось (online → offline)."""
        conns = self._connections.get(user_id)
        if not conns:
            return True
        conns.discard(ws)
        if not conns:
            self._connections.pop(user_id, None)
            return True
        return False

    def is_online(self, user_id: uuid.UUID) -> bool:
        return bool(self._connections.get(user_id))

    async def send_to_user(self, user_id: uuid.UUID, payload: dict[str, Any], *, exclude: WebSocket | None = None) -> None:
        conns = list(self._connections.get(user_id, ()))
        if not conns:
            return
        data = json.dumps(payload, default=str)
        for ws in conns:
            if ws is exclude:
                continue
            try:
                await ws.send_text(data)
            except Exception:
                pass  # сокет уже мёртв — закрытие придёт отдельным WebSocketDisconnect


manager = ConnectionManager()
