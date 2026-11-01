from __future__ import annotations

from dataclasses import asdict
from typing import Any

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel

from ..deps import get_current_user
from ..models import User
from .base import registry

router = APIRouter(prefix="/search", tags=["search"])


class SearchOut(BaseModel):
    hits: list[dict[str, Any]]
    sources: dict[str, dict[str, Any]]  # статус каждого модуля: ok / error


@router.get("", response_model=SearchOut)
async def search(q: str = Query(min_length=1, max_length=200), limit: int = Query(30, ge=1, le=100),
                 sources: str | None = None, user: User = Depends(get_current_user)):
    only = {s for s in sources.split(",") if s} if sources else None
    hits, status = await registry.search(user.id, q, limit, only=only)
    return SearchOut(hits=[asdict(h) for h in hits], sources=status)
