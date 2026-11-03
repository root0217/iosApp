# API v1 (кратко)

Все пути с префиксом `/v1`. Авторизация: `Authorization: Bearer <access_token>`.
Ошибки: `{"detail": {"code": "...", ...}}`.

**Авторизация** (идентификация по `username`, не по email; регистрация открытая):
- `GET /auth/username-available?username=...` — живая проверка доступности
- `POST /auth/register/start` {username, password} → {pending_id, recovery_code, expires_in}. Код показывается
  один раз, клиент обязан дать пользователю его переписать
- `POST /auth/register/confirm` {pending_id, recovery_code} → TokenPair (подтверждение кода создаёт аккаунт и сразу логинит)
- `POST /auth/login` {username, password, device_name?} → TokenPair. 3 неверных попытки → блокировка на 15 мин,
  дальше окно удваивается
- `POST /auth/refresh` {refresh_token} → TokenPair (refresh-токен одноразовый, при повторном предъявлении закрываются все сессии)
- `POST /auth/logout`, `GET /auth/me`, `GET /auth/sessions`, `DELETE /auth/sessions/{id}`
- `PATCH /auth/me/username` {username, current_password} — не чаще раза в 7 дней
- `POST /auth/me/password` {old_password, new_password} — закрывает остальные сессии
- `POST /auth/recover/password` {username, recovery_code, new_password}; `POST /auth/recover/username` {recovery_code} → {username}
- `POST /auth/me/delete` {password, recovery_code} — необратимо удаляет аккаунт и все его данные
- `GET /auth/search?q=...`, `GET /auth/users/{username}` — публичный профиль (username + avatar_url)
- `PUT /auth/me/avatar` (тело — сырые байты изображения, jpg/png/webp, ≤10 МБ) → автообрезка в квадрат и сжатие;
  `DELETE /auth/me/avatar`; `GET /auth/users/{id}/avatar` — сама картинка

Аккаунт с `is_admin=True` через API не создать — только CLI `python -m app.manage create-owner`, см. `docs/DEPLOY.md`.

**Библиотека** (`/library`):
- `GET /folders/{id|root}?sort=name|updated|size&order=asc|desc`: содержимое папки + «хлебные крошки»
- `POST /folders`, `PATCH /folders/{id}` (имя/перемещение), `DELETE /folders/{id}` (в корзину)
- `GET|PATCH|DELETE /files/{id}`, `PATCH`: имя, папка, `meta` (сливается). Заголовок `If-Match: <version>` защищает от конфликтов (409 `version_conflict`)
- Загрузка с докачкой: `POST /uploads` → `PUT /uploads/{id}?offset=N` (тело = байты куска) → `POST /uploads/{id}/complete`
  (`on_conflict`: `rename` | `fail` | `replace`; `sha256` необязателен, но проверяется). `GET /uploads/{id}` показывает, с какого байта продолжать.
- `GET|HEAD /files/{id}/content` (Range, `?download=true`), `POST /files/{id}/link` → короткая ссылка для плеера/предпросмотра
- `POST /zip` {file_ids, folder_ids}: потоковый ZIP
- `POST /bulk/delete`, `GET /trash`, `POST /trash/restore`, `POST /trash/purge` (безвозвратно)
- `GET /changes?cursor=N`: лента изменений для синхронизации (клиент хранит курсор)

**Поиск:** `GET /search?q=...&limit=30&sources=library`: единый поиск; в ответе статус каждого модуля.
