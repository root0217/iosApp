from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class _ORM(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class FolderOut(_ORM):
    id: uuid.UUID
    parent_id: uuid.UUID | None
    name: str
    version: int
    created_at: datetime
    updated_at: datetime
    deleted_at: datetime | None = None


class FileOut(_ORM):
    id: uuid.UUID
    folder_id: uuid.UUID | None
    name: str
    original_name: str
    extension: str
    mime_type: str
    size_bytes: int
    sha256: str
    version: int
    created_at: datetime
    updated_at: datetime
    deleted_at: datetime | None = None
    meta: dict[str, Any] = Field(default_factory=dict)


class Breadcrumb(BaseModel):
    id: uuid.UUID
    name: str


class ListingOut(BaseModel):
    folder: FolderOut | None
    breadcrumbs: list[Breadcrumb]
    folders: list[FolderOut]
    files: list[FileOut]


class FolderCreate(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    parent_id: uuid.UUID | None = None


class FolderPatch(BaseModel):
    name: str | None = Field(default=None, max_length=255)
    parent_id: uuid.UUID | None = None  # явный null = переместить в корень (смотрим model_fields_set)


class FilePatch(BaseModel):
    name: str | None = Field(default=None, max_length=255)
    folder_id: uuid.UUID | None = None  # явный null = в корень
    meta: dict[str, Any] | None = None  # сливается с текущими метаданными


class UploadCreate(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    size: int = Field(ge=0)
    folder_id: uuid.UUID | None = None
    mime_type: str | None = Field(default=None, max_length=127)
    for_message: bool = False  # вложение мессенджера: не попадёт ни в одну папку библиотеки


class UploadOut(BaseModel):
    id: uuid.UUID
    name: str
    size: int
    received: int
    folder_id: uuid.UUID | None
    expires_at: datetime


class CompleteIn(BaseModel):
    sha256: str | None = Field(default=None, min_length=64, max_length=64)
    on_conflict: Literal["rename", "fail", "replace"] = "rename"


class CompleteOut(BaseModel):
    file: FileOut
    duplicate_of: uuid.UUID | None = None  # такой же файл (по хэшу и размеру) уже есть; мы его не блокируем, а сообщаем
    replaced: bool = False


class IdsIn(BaseModel):
    file_ids: list[uuid.UUID] = Field(default_factory=list)
    folder_ids: list[uuid.UUID] = Field(default_factory=list)


class ZipIn(IdsIn):
    name: str | None = None


class BulkResult(BaseModel):
    files: int
    folders: int
    not_found: list[uuid.UUID]


class TrashOut(BaseModel):
    files: list[FileOut]
    folders: list[FolderOut]


class ChangeOut(BaseModel):
    seq: int
    entity_type: str
    entity_id: uuid.UUID
    op: str
    file: FileOut | None = None
    folder: FolderOut | None = None


class ChangesOut(BaseModel):
    changes: list[ChangeOut]
    cursor: int
    has_more: bool


class LinkOut(BaseModel):
    url: str
    expires_in: int


class UsageOut(BaseModel):
    used_bytes: int
