"""Служебные команды, которые не должны быть доступны через HTTP API.

Запуск внутри контейнера:
    docker compose exec api python -m app.manage create-owner

Создаёт аккаунт-владельца с username "chapa" и is_admin=True. Пишет в БД напрямую,
минуя /auth/register — поэтому не подчиняется проверке зарезервированных имён
(которая как раз и резервирует "chapa" для этого самого аккаунта) и не требует
открытой регистрации вообще.
"""
import argparse
import asyncio
import getpass
import sys

from . import db
from .auth.recovery import generate_recovery_code, hash_recovery_code
from .config import get_settings
from .models import User
from .passwords import hash_password
from sqlalchemy import select


async def create_owner(username: str) -> None:
    settings = get_settings()
    db.init_engine(settings.database_url)
    await db.create_schema()

    async with db.SessionLocal() as session:
        existing = await session.scalar(select(User).where(User.username == username))
        if existing is not None:
            print(f"Пользователь «{username}» уже существует (is_admin={existing.is_admin}).", file=sys.stderr)
            if not existing.is_admin:
                existing.is_admin = True
                await session.commit()
                print("Правам администратора выставлено: True.")
            return

        password = getpass.getpass(f"Пароль для «{username}»: ")
        password2 = getpass.getpass("Повторите пароль: ")
        if password != password2:
            print("Пароли не совпадают, отменено.", file=sys.stderr)
            raise SystemExit(1)

        code = generate_recovery_code()
        user = User(
            username=username,
            password_hash=hash_password(password),
            recovery_code_hash=hash_recovery_code(settings.secret_key, code),
            is_admin=True,
        )
        session.add(user)
        await session.commit()

        print(f"\nАккаунт «{username}» создан, is_admin=True.")
        print(f"RECOVERY-КОД (сохраните, больше нигде не показывается): {code}\n")


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.manage")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("create-owner", help="Создать или повысить до администратора аккаунт-владельца")
    p.add_argument("--username", default="chapa")
    args = parser.parse_args()

    if args.command == "create-owner":
        asyncio.run(create_owner(args.username))


if __name__ == "__main__":
    main()
