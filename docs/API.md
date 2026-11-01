# API v1 (кратко)

Все пути с префиксом `/v1`. Авторизация: `Authorization: Bearer <access_token>`.
Ошибки: `{"detail": {"code": "...", ...}}`.

**Авторизация:** `POST /auth/register` (только с `X-Setup-Token`), `POST /auth/login`, `POST /auth/refresh` (refresh-токен одноразовый, при повторном
предъявлении закрываются все сессии), `POST /auth/logout`, `GET /auth/me`, `GET /auth/sessions`, `DELETE /auth/sessions/{id}`.

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
