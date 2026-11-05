from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from sqlalchemy import Boolean, DateTime, ForeignKey, Index, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from ..db import Base
from ..models import utcnow

MessageType = Literal["text", "voice", "image", "file"]


class Conversation(Base):
    """Личная переписка 1:1. user_a_id < user_b_id всегда (см. messenger/service.canonical_pair) —
    это и есть уникальность пары без отдельного индекса по неупорядоченным двум столбцам."""

    __tablename__ = "conversations"
    __table_args__ = (UniqueConstraint("user_a_id", "user_b_id", name="uq_conversation_pair"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_a_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    user_b_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    last_message_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)


class ConversationMember(Base):
    """Состояние диалога на одного участника: закреплён ли у него, докуда прочитано, удалён ли у себя локально
    (для системного чата — «можно удалить только у себя», а здесь это же поле пригождается и для обычных)."""

    __tablename__ = "conversation_members"

    conversation_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("conversations.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True, index=True)
    pinned: Mapped[bool] = mapped_column(Boolean, default=False)
    last_read_message_id: Mapped[uuid.UUID | None] = mapped_column(nullable=True)
    hidden_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)  # «удалить у себя»


class Message(Base):
    __tablename__ = "messages"
    __table_args__ = (Index("ix_messages_conversation_sent", "conversation_id", "sent_at"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    conversation_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("conversations.id", ondelete="CASCADE"), index=True)
    sender_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    text: Mapped[str | None] = mapped_column(Text, nullable=True)
    attachment_file_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("files.id", ondelete="SET NULL"), nullable=True)
    attachment_duration_seconds: Mapped[float | None] = mapped_column(nullable=True)  # только для голосовых

    sent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    edited_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    deleted_for_everyone_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class MessageHiddenFor(Base):
    """«Удалить у себя» — у обеих сторон переписки независимо, не только у отправителя.
    Отдельная табличка вместо колонки на Message, потому что скрыть сообщение может любой
    из двух участников, и это не одно и то же, что deleted_for_everyone_at на самом Message."""

    __tablename__ = "message_hidden_for"

    message_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("messages.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    hidden_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
