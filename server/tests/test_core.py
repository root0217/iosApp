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
