import asyncio
import io
import tempfile
import time
import unittest
import zipfile
from pathlib import Path

import jwt

from app.library.ranges import RangeNotSatisfiable, parse_range
from app.library.zipstream import ZipEntry, stream_zip
from app.names import InvalidName, safe_name, split_ext, unique_name
from app.security import create_token, decode_token, hash_token, new_refresh_token
from app.storage.base import InvalidKey, ObjectNotFound, OffsetMismatch
from app.storage.local import LocalStorageProvider


def run(coro):
    return asyncio.run(coro)


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.s = LocalStorageProvider(Path(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def test_chunked_upload_commit_and_hash(self):
        import hashlib

        async def go():
            await self.s.staging_begin("a" * 32)
            n = await self.s.staging_write("a" * 32, 0, b"hello ")
            n = await self.s.staging_write("a" * 32, n, b"world")
            self.assertEqual(n, 11)
            key = self.s.new_key()
            obj = await self.s.staging_commit("a" * 32, key)
            self.assertEqual(obj.size, 11)
            self.assertEqual(obj.sha256, hashlib.sha256(b"hello world").hexdigest())
            self.assertEqual(await self.s.stat(key), 11)
            with self.assertRaises(ObjectNotFound):
                await self.s.staging_size("a" * 32)  # черновик исчез после commit
            return key

        run(go())

    def test_offset_mismatch_and_truncate_resume(self):
        async def go():
            uid = "b" * 32
            await self.s.staging_begin(uid)
            await self.s.staging_write(uid, 0, b"12345")
            with self.assertRaises(OffsetMismatch) as cm:
                await self.s.staging_write(uid, 3, b"x")
            self.assertEqual(cm.exception.expected, 5)
            await self.s.staging_truncate(uid, 3)  # «хвост» оборванного запроса отрезан
            self.assertEqual(await self.s.staging_size(uid), 3)
            await self.s.staging_write(uid, 3, b"45")
            with self.assertRaises(OffsetMismatch):
                await self.s.staging_truncate(uid, 99)  # нельзя «растягивать»

        run(go())

    def test_range_reads(self):
        async def go():
            uid = "c" * 32
            await self.s.staging_begin(uid)
            await self.s.staging_write(uid, 0, bytes(range(256)) * 10)
            key = self.s.new_key()
            await self.s.staging_commit(uid, key)

            async def read(a, b):
                return b"".join([c async for c in self.s.iter_range(key, a, b)])

            data = bytes(range(256)) * 10
            self.assertEqual(await read(0, 9), data[:10])
            self.assertEqual(await read(100, 2559), data[100:])
            self.assertEqual(await read(2559, 2559), data[-1:])
            await self.s.delete(key)
            await self.s.delete(key)  # идемпотентно
            with self.assertRaises(ObjectNotFound):
                await self.s.stat(key)

        run(go())

    def test_invalid_keys_rejected(self):
        for bad in ["../etc/passwd", "/etc/passwd", "ab/cd/../../x", "ab/cd/xyz", "", "aa/bb/" + "g" * 32]:
            with self.assertRaises(InvalidKey, msg=bad):
                run(self.s.stat(bad))
        with self.assertRaises(InvalidKey):
            run(self.s.staging_begin("../../x"))

    def test_list_objects_and_fresh_mtime(self):
        async def go():
            uid = "d" * 32
            await self.s.staging_begin(uid)
            await self.s.staging_write(uid, 0, b"x")
            key = self.s.new_key()
            await self.s.staging_commit(uid, key)
            objs = await self.s.list_objects()
            self.assertEqual([o.key for o in objs], [key])
            self.assertLess(time.time() - objs[0].mtime, 10)

        run(go())


class RangeTests(unittest.TestCase):
    def test_cases(self):
        self.assertIsNone(parse_range(None, 100))
        self.assertEqual(parse_range("bytes=0-9", 100), (0, 9))
        self.assertEqual(parse_range("bytes=90-", 100), (90, 99))
        self.assertEqual(parse_range("bytes=-10", 100), (90, 99))
        self.assertEqual(parse_range("bytes=50-5000", 100), (50, 99))
        self.assertIsNone(parse_range("bytes=0-1,5-6", 100))  # несколько диапазонов: отдаём целиком
        self.assertIsNone(parse_range("garbage", 100))
        with self.assertRaises(RangeNotSatisfiable):
            parse_range("bytes=100-", 100)
        with self.assertRaises(RangeNotSatisfiable):
            parse_range("bytes=-0", 100)


class ZipTests(unittest.TestCase):
    def test_stream_is_valid_zip(self):
        def make(data: bytes):
            async def gen():
                for i in range(0, len(data), 7):
                    yield data[i : i + 7]

            return gen

        big = bytes(range(256)) * 1000
        entries = [
            ZipEntry("док/readme.txt", (2026, 10, 31, 12, 0, 0), make("привет".encode())),
            ZipEntry("док/пустая", (2026, 10, 31, 12, 0, 0), None),
            ZipEntry("док/big.bin", (2026, 10, 31, 12, 0, 0), make(big)),
        ]

        async def collect():
            return b"".join([c async for c in stream_zip(entries)])

        blob = run(collect())
        zf = zipfile.ZipFile(io.BytesIO(blob))
        self.assertIsNone(zf.testzip())
        self.assertEqual(zf.read("док/readme.txt"), "привет".encode())
        self.assertEqual(zf.read("док/big.bin"), big)
        self.assertIn("док/пустая/", zf.namelist())


class NameTests(unittest.TestCase):
    def test_safe_name(self):
        self.assertEqual(safe_name("a/b\\c.txt"), "a_b_c.txt")
        self.assertEqual(safe_name("  x\x00y.pdf "), "xy.pdf")
        self.assertEqual(safe_name("exe\u202etxt"), "exetxt")  # RTL-override вырезан
        for bad in ["", "   ", ".", "..", None]:
            with self.assertRaises(InvalidName):
                safe_name(bad)
        long = safe_name("я" * 400 + ".pdf")
        self.assertEqual(len(long), 255)
        self.assertTrue(long.endswith(".pdf"))

    def test_split_and_unique(self):
        self.assertEqual(split_ext("a.tar.gz"), ("a.tar", "gz"))
        self.assertEqual(split_ext(".bashrc"), (".bashrc", ""))
        self.assertEqual(unique_name("a.txt", {"b.txt"}), "a.txt")
        self.assertEqual(unique_name("A.txt", {"a.txt"}), "A (1).txt")
        self.assertEqual(unique_name("a.txt", {"a.txt", "a (1).txt"}), "a (2).txt")
        self.assertEqual(unique_name("dir.v2", {"dir.v2"}, is_file=False), "dir.v2 (1)")


class TokenTests(unittest.TestCase):
    def test_roundtrip_and_types(self):
        t = create_token("secret", sub="u1", typ="access", ttl_seconds=60)
        self.assertEqual(decode_token("secret", t, typ="access")["sub"], "u1")
        with self.assertRaises(jwt.InvalidTokenError):
            decode_token("secret", t, typ="dl")  # токен другого назначения
        with self.assertRaises(jwt.InvalidTokenError):
            decode_token("other", t, typ="access")  # чужой ключ
        expired = create_token("secret", sub="u1", typ="access", ttl_seconds=-5)
        with self.assertRaises(jwt.ExpiredSignatureError):
            decode_token("secret", expired, typ="access")

    def test_refresh_hash(self):
        a, b = new_refresh_token(), new_refresh_token()
        self.assertNotEqual(a, b)
        self.assertEqual(len(hash_token(a)), 64)


if __name__ == "__main__":
    unittest.main()


# ---- этап 1: аккаунт Chapa (username, recovery-код, аватар) ----

from app.auth.avatars import InvalidImage, process_avatar
from app.auth.recovery import generate_recovery_code, hash_recovery_code, normalize_recovery_code, recovery_codes_match
from app.auth.reserved import RESERVED_USERNAMES
from app.auth.validators import normalize_username, password_error, username_error


class UsernameValidatorTests(unittest.TestCase):
    def test_valid(self):
        for name in ["abc", "a.b_c", "user123", "a" * 30, "my_friend.2"]:
            self.assertIsNone(username_error(name), name)

    def test_length(self):
        self.assertEqual(username_error("ab"), "invalid_format")
        self.assertEqual(username_error("a" * 31), "invalid_format")

    def test_charset(self):
        self.assertEqual(username_error("АБВ"), "invalid_format")  # кириллица
        self.assertEqual(username_error("has space"), "invalid_format")
        self.assertEqual(username_error("Upper"), "invalid_format")  # normalize_username должен быть вызван раньше

    def test_dots(self):
        self.assertEqual(username_error(".abc"), "dot_at_edge")
        self.assertEqual(username_error("abc."), "dot_at_edge")
        self.assertEqual(username_error("ab..c"), "consecutive_dots")
        self.assertIsNone(username_error("a.b.c"))

    def test_reserved(self):
        for name in ["admin", "chapa", "root", "support"]:
            self.assertIn(name, RESERVED_USERNAMES)
            self.assertEqual(username_error(name), "reserved")

    def test_normalize(self):
        self.assertEqual(normalize_username("  ChaPa_User  "), "chapa_user")


class PasswordValidatorTests(unittest.TestCase):
    def test_valid(self):
        for pw in ["password1", "P@ssw0rd!", "a" * 128, "12345678"]:
            self.assertIsNone(password_error(pw))

    def test_too_short_or_long(self):
        self.assertEqual(password_error("short1"), "invalid_characters")
        self.assertEqual(password_error("a" * 129), "invalid_characters")

    def test_cyrillic_and_space_rejected(self):
        self.assertEqual(password_error("пароль12"), "invalid_characters")
        self.assertEqual(password_error("has space1"), "invalid_characters")


class RecoveryCodeTests(unittest.TestCase):
    def test_generated_shape(self):
        code = generate_recovery_code()
        self.assertEqual(len(code), 27)  # 4 группы по 6 + 3 дефиса
        self.assertEqual(code.count("-"), 3)
        for ambiguous in "O0IL1":
            self.assertNotIn(ambiguous, code.replace("-", ""))

    def test_hash_is_deterministic_and_searchable(self):
        code = generate_recovery_code()
        h1 = hash_recovery_code("secret-a", code)
        h2 = hash_recovery_code("secret-a", code)
        self.assertEqual(h1, h2)  # детерминированность — нужна для поиска «забыли username»

    def test_different_secret_different_hash(self):
        code = generate_recovery_code()
        self.assertNotEqual(hash_recovery_code("secret-a", code), hash_recovery_code("secret-b", code))

    def test_verify_roundtrip_and_case_insensitive(self):
        code = generate_recovery_code()
        stored = hash_recovery_code("k", code)
        self.assertTrue(recovery_codes_match("k", code, stored))
        self.assertTrue(recovery_codes_match("k", code.lower(), stored))
        self.assertTrue(recovery_codes_match("k", f"  {code}  ", stored))
        self.assertFalse(recovery_codes_match("k", generate_recovery_code(), stored))

    def test_normalize(self):
        self.assertEqual(normalize_recovery_code(" ab-cd "), "AB-CD")


class AvatarProcessingTests(unittest.TestCase):
    def _make_image(self, size, fmt="JPEG", color=(200, 50, 50)):
        from PIL import Image
        buf = io.BytesIO()
        Image.new("RGB", size, color).save(buf, format=fmt)
        return buf.getvalue()

    def test_crops_to_square_and_resizes(self):
        from PIL import Image
        data = self._make_image((800, 400))  # широкое прямоугольное фото
        out = process_avatar(data, output_size=256)
        img = Image.open(io.BytesIO(out))
        self.assertEqual(img.format, "JPEG")
        self.assertEqual(img.size, (256, 256))

    def test_small_image_upscaled_to_output_size(self):
        from PIL import Image
        data = self._make_image((64, 64))
        out = process_avatar(data, output_size=512)
        img = Image.open(io.BytesIO(out))
        self.assertEqual(img.size, (512, 512))

    def test_png_and_webp_accepted(self):
        from PIL import Image
        for fmt in ("PNG", "WEBP"):
            out = process_avatar(self._make_image((300, 300), fmt=fmt), output_size=128)
            self.assertEqual(Image.open(io.BytesIO(out)).format, "JPEG")

    def test_garbage_rejected(self):
        with self.assertRaises(InvalidImage):
            process_avatar(b"not an image", output_size=256)

    def test_disallowed_format_rejected(self):
        from PIL import Image
        buf = io.BytesIO()
        Image.new("RGB", (100, 100)).save(buf, format="BMP")
        with self.assertRaises(InvalidImage):
            process_avatar(buf.getvalue(), output_size=256)


# ---- этап 2: мессенджер (чистая логика без БД) ----

import uuid as _uuid
from datetime import datetime, timedelta, timezone

from app.messenger.pure import canonical_pair, delivery_state, other_participant, within_edit_window


class CanonicalPairTests(unittest.TestCase):
    def test_order_independent_of_call_order(self):
        a, b = _uuid.uuid4(), _uuid.uuid4()
        self.assertEqual(canonical_pair(a, b), canonical_pair(b, a))

    def test_same_user_rejected(self):
        a = _uuid.uuid4()
        with self.assertRaises(ValueError):
            canonical_pair(a, a)

    def test_result_is_sorted_by_string(self):
        a, b = _uuid.uuid4(), _uuid.uuid4()
        lo, hi = canonical_pair(a, b)
        self.assertLessEqual(str(lo), str(hi))


class OtherParticipantTests(unittest.TestCase):
    def test_returns_the_other_side(self):
        a, b = _uuid.uuid4(), _uuid.uuid4()
        self.assertEqual(other_participant(a, b, a), b)
        self.assertEqual(other_participant(a, b, b), a)

    def test_non_member_rejected(self):
        a, b, stranger = _uuid.uuid4(), _uuid.uuid4(), _uuid.uuid4()
        with self.assertRaises(ValueError):
            other_participant(a, b, stranger)


class EditWindowTests(unittest.TestCase):
    def test_within_and_outside_window(self):
        now = datetime.now(timezone.utc)
        window = timedelta(hours=48)
        self.assertTrue(within_edit_window(now - timedelta(hours=1), now, window))
        self.assertTrue(within_edit_window(now - timedelta(hours=48), now, window))  # граница включительно
        self.assertFalse(within_edit_window(now - timedelta(hours=49), now, window))


class DeliveryStateTests(unittest.TestCase):
    def test_three_states(self):
        now = datetime.now(timezone.utc)
        self.assertEqual(delivery_state(None, None), "sent")
        self.assertEqual(delivery_state(now, None), "delivered")
        self.assertEqual(delivery_state(now, now), "read")

    def test_read_without_delivered_still_counts_as_read(self):
        # на практике read всегда идёт вместе с delivered (см. mark_read в service.py),
        # но функция сама по себе не должна требовать строгого порядка полей
        now = datetime.now(timezone.utc)
        self.assertEqual(delivery_state(None, now), "read")
