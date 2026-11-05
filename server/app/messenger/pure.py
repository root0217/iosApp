"""Логика без БД — вынесена отдельно специально, чтобы её можно было проверить юнит-тестами
без поднятия PostgreSQL (так же, как app/library/ranges.py и app/library/zipstream.py)."""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta


def canonical_pair(a: uuid.UUID, b: uuid.UUID) -> tuple[uuid.UUID, uuid.UUID]:
    """Диалог 1:1 хранится одной строкой на пару участников — порядок должен быть стабильным
    независимо от того, кто кому первый написал, иначе get-or-create создаст дубликат."""
    if a == b:
        raise ValueError("нельзя создать диалог с самим собой")
    return (a, b) if str(a) < str(b) else (b, a)


def other_participant(conv_user_a: uuid.UUID, conv_user_b: uuid.UUID, viewer_id: uuid.UUID) -> uuid.UUID:
    if viewer_id == conv_user_a:
        return conv_user_b
    if viewer_id == conv_user_b:
        return conv_user_a
    raise ValueError("viewer не является участником этого диалога")


def within_edit_window(sent_at: datetime, now: datetime, window: timedelta) -> bool:
    return now - sent_at <= window


def delivery_state(delivered_at: datetime | None, read_at: datetime | None) -> str:
    """Три состояния галочек: sent / delivered / read. read подразумевает delivered."""
    if read_at is not None:
        return "read"
    if delivered_at is not None:
        return "delivered"
    return "sent"
