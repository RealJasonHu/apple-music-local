"""Offline API/IPC tests: generated audio, fabricated cookies, no Apple requests."""
import asyncio
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

import imageio_ffmpeg
import mutagen
import worker


def cookie(path, value="SYNTHETIC_TOKEN", expiry=0):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("# Netscape HTTP Cookie File\n"
                    f".music.apple.com\tTRUE\t/\tTRUE\t{expiry}\tmedia-user-token\t{value}\n")


def media(index, total=2, partial=False, error=None, kind="songs"):
    return SimpleNamespace(index=index, total=total, media_id=str(index), partial=partial,
                           error=error, media_metadata={"type": kind, "attributes": {"name": f"Tone {index}"}})


class MockSession:
    def __init__(self, originals, sample, failure=False, enumeration_error=False):
        self.originals, self.sample = originals, sample
        self.failure, self.enumeration_error, self.closed = failure, enumeration_error, False

    async def media(self, url):
        container = media(None, kind="playlists", partial=True)
        container.media_metadata["relationships"] = {"tracks": {"data": [{"id": "0"}, {"id": "1"}]}}
        yield container
        for index in range(2):
            yield media(index, partial=True)
            if index == 1 and self.enumeration_error:
                raise RuntimeError("SECRET_ENUMERATION")
            yield media(index)

    async def download(self, item):
        if item.index == 1 and self.failure:
            raise RuntimeError("SECRET_TRACK")
        target = self.originals / "Synthetic Album" / f"{item.index}.m4a"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.sample, target)
        target.with_suffix(".lrc").write_text("[00:00.00]Synthetic\n")
        return target

    async def close(self):
        self.closed = True


class BackendTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory()
        cls.sample = Path(cls.shared.name) / "sample.m4a"
        subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-loglevel", "error",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3", "-c:a", "aac",
                        "-metadata", "title=Synthetic Test", str(cls.sample)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cookies = self.root / "private" / "cookies.txt"
        cookie(self.cookies)
        self.request = {"command": "download", "url": "https://music.apple.com/us/playlist/example/pl.example",
                        "format": "mp3", "output": str(self.root / "output"),
                        "cookie_path": str(self.cookies), "job_id": "job-test"}
        self.events, self.sessions = [], []

    def factory(self, **options):
        async def build(cookie_path, originals, temporary, ffmpeg):
            session = MockSession(originals, self.sample, **options)
            self.sessions.append(session)
            return session
        return build

    async def test_partial_failure_is_not_whole_playlist_success(self):
        result = await worker.download(self.request, self.events.append, self.factory(failure=True))
        self.assertEqual((result["status"], result["succeeded"], result["failed"], result["total"]), ("partial", 1, 1, 2))
        self.assertEqual(len(result["files"]), 1)
        self.assertEqual(len(result["original_files"]), 1)
        self.assertNotIn("SECRET_TRACK", json.dumps(self.events))
        audio = mutagen.File(result["files"][0])
        self.assertAlmostEqual(audio.info.bitrate, 320000, delta=1000)
        self.assertTrue(Path(result["files"][0]).with_suffix(".lrc").exists())
        self.assertTrue(self.sessions[0].closed)
        self.assertFalse(list((self.root / "output").glob(".applemusic-*")))

    async def test_incomplete_enumeration_preserves_partial_result(self):
        result = await worker.download(self.request, self.events.append, self.factory(enumeration_error=True))
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["failed"], 1)
        self.assertIn("未完整读取", result["message"])
        self.assertNotIn("SECRET_ENUMERATION", json.dumps(self.events))

    async def test_final_failure_retains_actionable_safe_reason(self):
        async def no_subscription(*args):
            raise worker.UserError("当前登录未验证到有效的 Apple Music 订阅，请确认会员并重新导入登录。")
        result = await worker.download(self.request, self.events.append, no_subscription)
        self.assertEqual(result["status"], "failed")
        self.assertIn("重新导入登录", result["message"])
        self.request["job_id"] = "secret-failure"
        async def upstream_error(*args):
            raise RuntimeError("SECRET_UPSTREAM_TOKEN")
        result = await worker.download(self.request, self.events.append, upstream_error)
        self.assertNotIn("SECRET_UPSTREAM_TOKEN", json.dumps(result))
        self.assertIn("检查网络", result["message"])

    async def test_wav_conversion_and_aac_originals(self):
        self.request["format"] = "wav"
        result = await worker.download(self.request, self.events.append, self.factory())
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["succeeded"], 2)
        self.assertIn("不会提升音质", result["message"])
        for file in result["files"]:
            self.assertEqual(mutagen.File(file).info.bits_per_sample, 24)
        for file in result["original_files"]:
            self.assertEqual(Path(file).read_bytes(), self.sample.read_bytes())
        self.request["job_id"] = "aac-job"
        self.request["format"] = "aac"
        result = await worker.download(self.request, self.events.append, self.factory())
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["files"], result["original_files"])
        self.assertEqual(Path(result["output"]), (self.root / "output" / "Originals" / "aac-job").resolve())

    async def test_missing_cookies_and_file_destination_fail_before_network(self):
        factory = AsyncMock()
        self.cookies.unlink()
        with self.assertRaises(worker.UserError):
            await worker.download(self.request, self.events.append, factory)
        factory.assert_not_called()
        self.assertFalse((self.root / "output").exists())
        cookie(self.cookies)
        (self.root / "output").write_text("keep this file")
        with self.assertRaises(worker.UserError):
            await worker.download(self.request, self.events.append, factory)
        self.assertEqual((self.root / "output").read_text(), "keep this file")
        factory.assert_not_called()

    async def test_job_directory_cannot_overwrite_previous_job(self):
        result = await worker.download(self.request, self.events.append, self.factory())
        before = Path(result["files"][0]).stat().st_mtime_ns
        with self.assertRaises(worker.UserError):
            await worker.download(self.request, self.events.append, self.factory())
        self.assertEqual(Path(result["files"][0]).stat().st_mtime_ns, before)

    async def test_cookie_filtering_permissions_session_and_expiry(self):
        source = self.root / "browser-cookies.txt"
        cookie(source)
        with source.open("a") as stream:
            stream.write(".example.com\tTRUE\t/\tTRUE\t0\tpassword\tOTHER_SECRET\n")
            stream.write(".apple.com\tTRUE\t/\tTRUE\t0\taccount\tACCOUNT_SECRET\n")
        target = self.root / "imported" / "cookies.txt"
        result = await worker.handle({"command": "import_cookies", "source": str(source), "cookie_path": str(target)}, self.events.append)
        self.assertTrue(result["valid"])
        self.assertEqual(worker.cookie_token(target), ("SYNTHETIC_TOKEN", 0))
        self.assertNotIn("OTHER_SECRET", target.read_text())
        self.assertNotIn("ACCOUNT_SECRET", target.read_text())
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o700)
        result = await worker.handle({"command": "auth_status", "cookie_path": str(target)}, self.events.append)
        self.assertTrue(result["valid"])
        cookie(target, expiry=int(time.time()) - 10)
        result = await worker.handle({"command": "auth_status", "cookie_path": str(target)}, self.events.append)
        self.assertFalse(result["valid"])

    async def test_actual_gamdl_adapter_uses_only_aac_web(self):
        from gamdl.api import AppleMusicApi
        from gamdl.interface import AppleMusicBaseInterface
        from gamdl.interface.enums import SongCodec
        api = SimpleNamespace(active_subscription=True, client=SimpleNamespace(aclose=AsyncMock()))
        base = SimpleNamespace(wrapper_api=None, itunes_api=SimpleNamespace(client=SimpleNamespace(aclose=AsyncMock())))
        with patch.object(AppleMusicApi, "create", AsyncMock(return_value=api)), \
             patch.object(AppleMusicBaseInterface, "create", AsyncMock(return_value=base)):
            session = await worker.build_session(self.cookies, self.root, self.root, imageio_ffmpeg.get_ffmpeg_exe())
        self.assertEqual(session.base_interface.song.codec_priority, [SongCodec.AAC_WEB])
        self.assertTrue(session.downloader.base.silent)
        self.assertIsNone(session.base.wrapper_api)
        await session.close()

    async def test_verify_account_reports_only_subscription_and_country(self):
        from gamdl.api import AppleMusicApi
        account = {"meta": {"subscription": {"active": True, "storefront": "SG"}},
                   "data": [{"attributes": {"email": "PRIVATE_ACCOUNT_DETAIL"}}]}
        with patch.object(AppleMusicApi, "get_token", AsyncMock(return_value="DEVELOPER_SECRET")), \
             patch.object(AppleMusicApi, "get_account_info", AsyncMock(return_value=account)):
            result = await worker.handle({"command": "verify_account", "cookie_path": str(self.cookies)}, self.events.append)
        self.assertEqual((result["status"], result["authenticated"], result["subscription"], result["storefront"]),
                         ("completed", True, True, "sg"))
        self.assertNotIn("PRIVATE_ACCOUNT_DETAIL", json.dumps(result))
        self.assertNotIn("DEVELOPER_SECRET", json.dumps(result))
        self.assertNotIn("SYNTHETIC_TOKEN", json.dumps(result))
        account["meta"]["subscription"]["active"] = False
        with patch.object(AppleMusicApi, "get_token", AsyncMock(return_value="test")), \
             patch.object(AppleMusicApi, "get_account_info", AsyncMock(return_value=account)):
            result = await worker.verify_account({"cookie_path": str(self.cookies)})
        self.assertEqual(result["status"], "completed")
        self.assertTrue(result["authenticated"])
        self.assertFalse(result["subscription"])

    async def test_verify_distinguishes_invalid_auth_from_network_failure(self):
        from gamdl.api import AppleMusicApi
        from gamdl.api.exceptions import GamdlApiResponseError
        for code, invalid in [(401, True), (403, True), (429, False), (503, False), (None, False)]:
            error = GamdlApiResponseError("SECRET_ERROR", content="SECRET_CONTENT", status_code=code)
            with self.subTest(code=code), patch.object(AppleMusicApi, "get_token", AsyncMock(return_value="test")), \
                 patch.object(AppleMusicApi, "get_account_info", AsyncMock(side_effect=error)):
                result = await worker.verify_account({"cookie_path": str(self.cookies)})
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["auth_invalid"], invalid)
            self.assertEqual(result["network_failure"], not invalid)
            self.assertEqual(result["retryable"], not invalid)
            self.assertNotIn("SECRET", json.dumps(result))
        # Failure fetching Apple's public developer token does not invalidate the user's login.
        with patch.object(AppleMusicApi, "get_token", AsyncMock(side_effect=GamdlApiResponseError("hidden", status_code=403))):
            result = await worker.verify_account({"cookie_path": str(self.cookies)})
        self.assertFalse(result["auth_invalid"])
        self.assertTrue(result["network_failure"])
        cookie(self.cookies, expiry=int(time.time()) - 1)
        with patch.object(AppleMusicApi, "get_token", AsyncMock()) as fetch:
            result = await worker.verify_account({"cookie_path": str(self.cookies)})
        fetch.assert_not_called()
        self.assertTrue(result["auth_invalid"])

    def catalog_api(self, kind="songs"):
        path_kind = {"songs": "song", "albums": "album", "playlists": "playlist"}[kind]
        item = {"id": "123", "type": kind, "attributes": {"name": "Test Title", "artistName": "Test Artist",
                "albumName": "Test Album", "url": f"https://music.apple.com/sg/{path_kind}/test/123",
                "artwork": {"url": "https://is1-ssl.mzstatic.com/image/test/{w}x{h}bb.{f}"},
                "durationInMillis": 120000, "trackCount": 8, "contentRating": "explicit"}}
        response = {"results": {kind: {"data": [item], "next": "/v1/catalog/sg/search?offset=25&limit=25"}}}
        api = SimpleNamespace(client=SimpleNamespace(aclose=AsyncMock()), get_search_results=AsyncMock(return_value=response))
        return api, item

    async def test_catalog_search_uses_account_region_and_explicit_pagination(self):
        from gamdl.api import AppleMusicApi
        api, _ = self.catalog_api()
        account = {"meta": {"subscription": {"active": True, "storefront": "sg"}}}
        with patch.object(AppleMusicApi, "get_token", AsyncMock(return_value="developer")), \
             patch.object(AppleMusicApi, "get_account_info", AsyncMock(return_value=account)), \
             patch.object(AppleMusicApi, "create", AsyncMock(return_value=api)) as create:
            result = await worker.search_catalog({"query": "测试音乐", "kind": "songs", "limit": 25, "offset": 0,
                                                  "cookie_path": str(self.cookies), "storefront": "us"})
        create.assert_awaited_once_with(storefront="sg", token="developer")
        api.get_search_results.assert_awaited_once_with(term="测试音乐", types="songs", limit=25, offset=0)
        api.client.aclose.assert_awaited_once()
        self.assertEqual(result["storefront_source"], "account")
        self.assertTrue(result["authenticated"])
        self.assertTrue(result["has_more"])
        self.assertEqual(result["next_offset"], 25)
        track = result["results"][0]
        self.assertEqual(track["artwork_url"], "https://is1-ssl.mzstatic.com/image/test/600x600bb.jpg")
        self.assertEqual(track["album"], "Test Album")
        self.assertEqual(track["duration_ms"], 120000)
        self.assertTrue(track["explicit"])

    async def test_public_search_without_login_and_with_invalid_cookie(self):
        from gamdl.api import AppleMusicApi
        from gamdl.api.exceptions import GamdlApiResponseError
        for request, invalid in [({"query": "test", "kind": "albums"}, False),
                                 ({"query": "test", "kind": "albums", "cookie_path": str(self.cookies)}, True)]:
            api, _ = self.catalog_api("albums")
            api.get_search_results.return_value["results"]["albums"].pop("next")
            with patch.object(AppleMusicApi, "get_token", AsyncMock(return_value="developer")), \
                 patch.object(AppleMusicApi, "get_account_info", AsyncMock(side_effect=GamdlApiResponseError("secret", status_code=401))), \
                 patch.object(AppleMusicApi, "create", AsyncMock(return_value=api)) as create:
                result = await worker.search_catalog(request)
            self.assertEqual(result["status"], "completed")
            self.assertEqual(result["auth_invalid"], invalid)
            self.assertFalse(result["authenticated"])
            self.assertEqual(result["storefront"], "us")
            self.assertEqual(result["storefront_source"], "public")
            self.assertFalse(result["has_more"])
            self.assertIsNone(result["next_offset"])
            self.assertEqual(result["results"][0]["album"], "Test Title")
            create.assert_awaited_once_with(storefront="us", token="developer")

    async def test_search_network_fallback_and_catalog_failure_are_safe(self):
        from gamdl.api import AppleMusicApi
        api, _ = self.catalog_api("playlists")
        with patch.object(AppleMusicApi, "get_token", AsyncMock(return_value="developer")), \
             patch.object(AppleMusicApi, "get_account_info", AsyncMock(side_effect=RuntimeError("SECRET_NETWORK"))), \
             patch.object(AppleMusicApi, "create", AsyncMock(return_value=api)):
            result = await worker.search_catalog({"query": "test", "kind": "playlists", "cookie_path": str(self.cookies)})
        self.assertEqual(result["status"], "completed")
        self.assertTrue(result["network_failure"])
        self.assertTrue(result["retryable"])
        self.assertNotIn("SECRET_NETWORK", json.dumps(result))
        api.get_search_results.side_effect = RuntimeError("SECRET_CATALOG")
        with patch.object(AppleMusicApi, "get_token", AsyncMock(return_value="developer")), \
             patch.object(AppleMusicApi, "create", AsyncMock(return_value=api)):
            result = await worker.search_catalog({"query": "test", "kind": "playlists"})
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["retryable"])
        self.assertFalse(result["auth_invalid"])
        self.assertNotIn("SECRET_CATALOG", json.dumps(result))

    async def test_catalog_links_are_restricted_and_bad_requests_skip_network(self):
        from gamdl.api import AppleMusicApi
        _, item = self.catalog_api()
        for value in ["https://music.apple.com.evil.test/us/song/test/123", "http://music.apple.com/us/song/test/123",
                      "https://password@music.apple.com/us/song/test/123", "https://music.apple.com/us/artist/test/123"]:
            item["attributes"]["url"] = value
            self.assertIsNone(worker.search_item(item, "songs"))
        item["attributes"]["url"] = "https://music.apple.com/us/album/test/123?i=456"
        item["attributes"]["artwork"]["url"] = "https://mzstatic.com.evil.test/image.jpg"
        self.assertEqual(worker.search_item(item, "songs")["artwork_url"], "")
        for request in [{"query": ""}, {"query": "x", "kind": "artists"}, {"query": "x", "limit": 100},
                        {"query": "x", "offset": -1}, {"query": "x", "storefront": "../"}]:
            with patch.object(AppleMusicApi, "get_token", AsyncMock()) as fetch:
                result = await worker.search_catalog(request)
            self.assertEqual(result["status"], "failed")
            fetch.assert_not_called()

    def test_url_validation_rejects_other_hosts_artists_and_credentials(self):
        for url in ["http://music.apple.com/us/song/name/1", "https://evil.test/us/song/name/1",
                    "https://music.apple.com.evil.test/us/song/name/1", "https://music.apple.com/us/artist/name/1",
                    "https://user:password@music.apple.com/us/song/name/1"]:
            with self.subTest(url=url), self.assertRaises(worker.UserError):
                worker.validate_download(dict(self.request, url=url))

    def run_ipc(self, request):
        process = subprocess.run([sys.executable, str(Path(worker.__file__))], input=json.dumps(request) + "\n",
                                 text=True, capture_output=True, timeout=15)
        events = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(process.stderr, "")
        self.assertTrue(events)
        self.assertEqual(events[-1]["event"], "done")
        return process, events

    def test_ipc_malformed_cookie_does_not_leak_contents(self):
        source = self.root / "bad-cookie.txt"
        source.write_text("# Netscape HTTP Cookie File\nMALFORMED_SECRET_LINE\n")
        process, events = self.run_ipc({"command": "import_cookies", "source": str(source), "cookie_path": str(self.cookies)})
        self.assertEqual(events[-1]["status"], "failed")
        self.assertNotIn("MALFORMED_SECRET_LINE", process.stdout + process.stderr)
        self.assertEqual(worker.cookie_token(self.cookies)[0], "SYNTHETIC_TOKEN")

    def test_ipc_self_test_is_successful_json_only(self):
        process, events = self.run_ipc({"command": "self_test"})
        self.assertEqual(process.returncode, 0)
        self.assertEqual(events[-1]["versions"]["gamdl"], "3.9.1")

    def test_process_group_cancel_stops_child_and_preserves_completed_track(self):
        request = dict(self.request, format="aac", sample=str(self.sample))
        process = subprocess.Popen([sys.executable, __file__, "--cancel-fixture"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        child_pid = None
        first_events = []
        deadline = time.monotonic() + 15
        import select
        while time.monotonic() < deadline:
            if not select.select([process.stdout], [], [], 1)[0]:
                continue
            line = process.stdout.readline()
            if not line:
                break
            event = json.loads(line)
            first_events.append(event)
            if "child_pid" in event:
                child_pid = event["child_pid"]
                break
        self.assertIsNotNone(child_pid, first_events)
        os.killpg(process.pid, signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        events = first_events + [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual(stderr, "")
        self.assertEqual(events[-1]["status"], "cancelled")
        self.assertEqual(events[-1]["succeeded"], 1)
        self.assertTrue(Path(events[-1]["files"][0]).exists())
        self.assertFalse(list((self.root / "output").glob(".applemusic-*")))
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)


def cancellation_fixture():
    async def handle(request, emit):
        class SlowSession(MockSession):
            async def download(self, item):
                if item.index == 0:
                    return await super().download(item)
                child = await asyncio.create_subprocess_exec(sys.executable, "-c", "import time; time.sleep(60)")
                emit({"event": "progress", "message": "fixture-ready", "completed": 1, "total": 2, "child_pid": child.pid})
                try:
                    await child.wait()
                finally:
                    if child.returncode is None:
                        try:
                            child.terminate()
                        except ProcessLookupError:
                            pass
                    await child.wait()
        async def factory(cookie_path, originals, temporary, ffmpeg):
            return SlowSession(originals, Path(request["sample"]))
        return await worker.download(request, emit, factory)
    worker.handle = handle
    sys.exit(worker.main())


if __name__ == "__main__":
    if "--cancel-fixture" in sys.argv:
        cancellation_fixture()
    else:
        unittest.main(verbosity=2)
