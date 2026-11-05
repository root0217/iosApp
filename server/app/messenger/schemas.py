from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field

from ..auth.router import PublicUserOut


class AttachmentOut(BaseModel):
    id: uuid.UUID
    name: str
    mime_type: str
    size_bytes: int
    duration_seconds: float | None = None


class MessageOut(BaseModel):
    id: uuid.UUID
    conversation_id: uuid.UUID
    sender_id: uuid.UUID
    text: str | None
    attachment: AttachmentOut | None
    sent_at: datetime
    status: str  # sent | delivered | read (относительно получателя)
    edited_at: datetime | None
    deleted_for_everyone: bool


class ConversationOut(BaseModel):
    id: uuid.UUID
    participant: PublicUserOut
    last_message: MessageOut | None
    unread_count: int
    pinned: bool
    updated_at: datetime


class StartConversationIn(BaseModel):
    username: str = Field(min_length=1, max_length=30)


class SendMessageIn(BaseModel):
    text: str | None = Field(default=None, max_length=4096)
    attachment_file_id: uuid.UUID | None = None
    attachment_duration_seconds: float | None = Field(default=None, ge=0, le=3600)


class EditMessageIn(BaseModel):
    text: str = Field(min_length=1, max_length=4096)


class MarkReadIn(BaseModel):
    up_to_message_id: uuid.UUID


class PinIn(BaseModel):
    pinned: bool


class MessagesPage(BaseModel):
    messages: list[MessageOut]
    has_more: bool
