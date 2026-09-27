#!/usr/bin/env python3
"""One-request JSON-lines backend. No credentials or library logs reach the UI."""
from __future__ import annotations

import asyncio
from contextlib import suppress
import importlib.metadata
import json
import logging
import os
from pathlib import Path
import re
import shutil
import signal
import sys
import tempfile
import time
from urllib.parse import urlsplit, unquote, parse_qs


class UserError(Exception):
    """A fixed, safe message written by this application, never upstream text."""


def cookie_token(path: Path) -> tuple[str, int]:
    try:
        if not path.is_file() or path.stat().st_size > 2_000_000:
            raise UserError("请选择有效的 Netscape cookies.txt 文件。")
        lines = path.read_text(encoding="utf-8-sig").splitlines()
        if not lines or not any("Cookie File" in line for line in lines[:3]):
            raise UserError("Cookie 文件格式不正确，请导出 Netscape 格式后重新导入。")
        selected = None
        for line in lines:
            if line.startswith("#HttpOnly_"):
                line = line[len("#HttpOnly_"):]
            elif not line.strip() or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 7:
                raise UserError("Cookie 文件格式不正确，请重新导出；文件内容不会记录到日志。")
            domain, flag, cookie_path, secure, expiry, name, value = fields
            if flag not in {"TRUE", "FALSE"} or secure not in {"TRUE", "FALSE"}:
                raise UserError("Cookie 文件格式不正确，请重新导出。")
            if domain.lstrip(".").lower() != "music.apple.com" or name != "media-user-token":
                continue
            if not expiry.isdigit() or not value or any(ord(c) < 33 or ord(c) > 126 or c == ";" for c in value):
                raise UserError("Apple Music 登录凭据格式不正确，请重新导出。")
            expires = int(expiry)
            if expires and expires <= time.time():
                continue
            selected = (value, expires)  # Expiry 0 denotes a session cookie.
        if selected is None:
            raise UserError("未找到有效的 Apple Music 登录凭据，请登录网页后重新导出。")
        return selected
    except UserError:
        raise
    except (OSError, UnicodeError, ValueError):
        raise UserError("无法读取 Cookie 文件，请重新选择 Netscape 格式的文件。") from None


def private_cookie_import(source: Path, target: Path) -> None:
    token, expiry = cookie_token(source)
    if target.is_symlink() or target.parent.is_symlink():
        raise UserError("登录凭据目录不能是符号链接。")
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    target.parent.chmod(0o700)
    fd, temporary = tempfile.mkstemp(prefix=".cookies-", dir=target.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
            output.write("# Netscape HTTP Cookie File\n")
            output.write(f".music.apple.com\tTRUE\t/\tTRUE\t{expiry}\tmedia-user-token\t{token}\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)


def path_argument(request: dict, key: str) -> Path:
    value = request.get(key)
    if not isinstance(value, str) or not value or "\0" in value:
        raise UserError("请求缺少有效的本地文件路径。")
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise UserError("本地路径必须是完整路径。")
    return path


def validate_download(request: dict) -> tuple[str, str, Path, str]:
    url = request.get("url", "")
    if not isinstance(url, str) or len(url) > 8192:
        raise UserError("请输入 Apple Music 歌曲、专辑或歌单链接。")
    try:
        parsed = urlsplit(url.strip())
        parts = [unquote(part) for part in parsed.path.split("/") if part]
        valid = (parsed.scheme == "https" and parsed.hostname == "music.apple.com"
                 and parsed.port in (None, 443) and not parsed.username and not parsed.password
                 and len(parts) >= 3 and re.fullmatch(r"[a-zA-Z]{2}", parts[0])
                 and parts[1] in {"song", "album", "playlist"}
                 and all(part not in {".", ".."} and "/" not in part for part in parts))
    except ValueError:
        valid = False
    if not valid:
        raise UserError("仅支持 https://music.apple.com 的歌曲、专辑或歌单链接。")
    format_ = request.get("format")
    if format_ not in {"mp3", "wav", "aac"}:
        raise UserError("请选择 MP3、WAV 或 AAC 格式。")
    job_id = request.get("job_id", "")
    if not isinstance(job_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", job_id):
        raise UserError("任务编号无效，请重新开始任务。")
    output = path_argument(request, "output").resolve()
    if output.exists() and not output.is_dir():
        raise UserError("保存位置必须是文件夹，不能是文件。")
    return url.strip(), format_, output, job_id


def safe_error(error: Exception) -> str:
    if isinstance(error, UserError):
        return str(error)
    code = getattr(error, "status_code", None)
    if code in (401, 403):
        return "登录凭据失效或当前账户无权访问，请重新导入登录。"
    if code == 429:
        return "Apple Music 暂时限制了请求频率，请稍后重试。"
    if code == 404:
        return "该内容在当前地区或账户中不可用。"
    name = type(error).__name__
    if name in {"GamdlInterfaceMediaNotStreamableError", "GamdlInterfaceFormatNotAvailableError",
                "GamdlInterfaceDecryptionNotAvailableError", "GamdlInterfaceMediaNotAllowedError"}:
        return "该曲目当前无法以 AAC 网页音源获取，或内容类型不受支持。"
    if isinstance(error, PermissionError):
        return "无法写入所选文件夹，请重新选择有写入权限的位置。"
    return "处理失败，请检查网络、登录状态、内容可用性及磁盘空间后重试。"


def done_result(**fields) -> dict:
    return {"event": "done", "status": "completed", "message": "", "files": [], "output": "", **fields}


def http_status(error: Exception) -> int | None:
    value = getattr(error, "status_code", None)
    if value is None:
        value = getattr(getattr(error, "response", None), "status_code", None)
    return value if isinstance(value, int) else None


def account_summary(account: dict) -> tuple[bool, str]:
    """Extract only subscription/region; callers never emit the account object."""
    if not isinstance(account, dict) or account.get("errors"):
        raise RuntimeError("Account response unavailable")
    subscription = account.get("meta", {}).get("subscription")
    if not isinstance(subscription, dict):
        raise RuntimeError("Account subscription response unavailable")
    region = subscription.get("storefront", "")
    region = region.lower() if isinstance(region, str) and re.fullmatch(r"[a-zA-Z]{2}", region) else ""
    return subscription.get("active") is True, region


def account_failure(error: Exception, *, authentication_stage: bool = True) -> dict:
    invalid = isinstance(error, UserError) or (authentication_stage and http_status(error) in (401, 403))
    return done_result(status="failed", authenticated=False, subscription=False, storefront="",
                       auth_invalid=invalid, network_failure=not invalid, retryable=not invalid,
                       message=("登录凭据缺失、过期或已失效，请在 Apple Music 网页重新登录并导入凭据。"
                                if invalid else "暂时无法连接 Apple Music 验证账户，请检查网络后重试；现有登录凭据已保留。"))


async def verify_account(request: dict) -> dict:
    from gamdl.api import AppleMusicApi
    authentication_stage = False
    try:
        token, _ = cookie_token(path_argument(request, "cookie_path"))
        async with asyncio.timeout(35):
            developer_token = await AppleMusicApi.get_token()
            authentication_stage = True
            account = await AppleMusicApi.get_account_info(developer_token, token)
        subscribed, region = account_summary(account)
        return done_result(authenticated=True, subscription=subscribed, storefront=region,
                           auth_invalid=False, network_failure=False, retryable=False,
                           message=(f"账户验证成功，Apple Music 订阅有效（{region.upper() or '地区未提供'}）。"
                                    if subscribed else "账户登录有效，但未验证到有效的 Apple Music 订阅；可以搜索，下载需要有效订阅。"))
    except Exception as error:
        return account_failure(error, authentication_stage=authentication_stage)


def safe_metadata_url(value, kind: str | None = None) -> str:
    if not isinstance(value, str) or len(value) > 8192 or any(ord(c) < 32 for c in value):
        return ""
    try:
        parsed = urlsplit(value)
        if (parsed.scheme != "https" or parsed.username or parsed.password
                or parsed.port not in (None, 443)):
            return ""
        if kind is None:
            host = parsed.hostname or ""
            if not (host == "mzstatic.com" or host.endswith(".mzstatic.com")):
                return ""
            result = value.replace("{w}", "600").replace("{h}", "600").replace("{f}", "jpg")
            return "" if "{" in result or "}" in result else result
        parts = [unquote(part) for part in parsed.path.split("/") if part]
        allowed = {"songs": {"song", "album"}, "albums": {"album"}, "playlists": {"playlist"}}[kind]
        if (parsed.hostname != "music.apple.com" or len(parts) < 3
                or not re.fullmatch(r"[a-zA-Z]{2}", parts[0]) or parts[1] not in allowed
                or any(part in {".", ".."} or "/" in part for part in parts)):
            return ""
        return value
    except (ValueError, KeyError):
        return ""


def search_item(item: dict, kind: str) -> dict | None:
    if not isinstance(item, dict) or item.get("type") != kind:
        return None
    attributes = item.get("attributes", {})
    if not isinstance(attributes, dict):
        return None
    url = safe_metadata_url(attributes.get("url"), kind)
    identifier, title = item.get("id"), attributes.get("name")
    if not url or not isinstance(identifier, str) or not isinstance(title, str):
        return None
    def text_value(key):
        value = attributes.get(key, "")
        return value[:1000] if isinstance(value, str) else ""
    def number(key):
        value = attributes.get(key)
        return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0
    artwork = attributes.get("artwork") or {}
    artwork_url = safe_metadata_url(artwork.get("url")) if isinstance(artwork, dict) else ""
    return {"id": identifier, "kind": kind, "title": title[:1000],
            "artist": text_value("artistName") or text_value("curatorName"),
            "album": text_value("albumName") if kind == "songs" else (title[:1000] if kind == "albums" else ""),
            "url": url, "artwork_url": artwork_url, "duration_ms": number("durationInMillis"),
            "track_count": number("trackCount"), "explicit": attributes.get("contentRating") == "explicit"}


async def search_catalog(request: dict) -> dict:
    from gamdl.api import AppleMusicApi
    api = None
    state = {"results": [], "storefront": "us", "storefront_source": "public", "authenticated": False,
             "subscription": False, "auth_invalid": False, "network_failure": False, "retryable": False,
             "has_more": False, "next_offset": None}
    try:
        query, kind = request.get("query"), request.get("kind", "songs")
        limit, offset = request.get("limit", 25), request.get("offset", 0)
        if not isinstance(query, str) or not query.strip() or len(query) > 256 or any(ord(c) < 32 for c in query):
            raise UserError("请输入 1 至 256 个字符的搜索关键词。")
        if kind not in {"songs", "albums", "playlists"}:
            raise UserError("请选择歌曲、专辑或歌单搜索。")
        if (type(limit) is not int or not 1 <= limit <= 25 or type(offset) is not int or not 0 <= offset <= 100000):
            raise UserError("搜索分页参数无效。")
        storefront = request.get("storefront", "us")
        if not isinstance(storefront, str) or not re.fullmatch(r"[a-zA-Z]{2}", storefront):
            raise UserError("目录地区必须是两个字母的国家或地区代码。")
        state["storefront"] = storefront.lower()
        async with asyncio.timeout(45):
            developer_token = await AppleMusicApi.get_token()
            media_token = None
            if request.get("cookie_path"):
                try:
                    media_token, _ = cookie_token(path_argument(request, "cookie_path"))
                except UserError:
                    state["auth_invalid"] = True
            if media_token:
                try:
                    account = await AppleMusicApi.get_account_info(developer_token, media_token)
                    subscription, region = account_summary(account)
                    state.update(authenticated=True, subscription=subscription)
                    if region:
                        state.update(storefront=region, storefront_source="account")
                except Exception as error:
                    if http_status(error) in (401, 403):
                        state["auth_invalid"] = True
                    else:
                        state.update(network_failure=True, retryable=True)
            # Catalog metadata requests need only Apple's developer token. Do
            # not send the user's account cookie to artwork hosts or other services.
            api = await AppleMusicApi.create(storefront=state["storefront"], token=developer_token)
            response = await api.get_search_results(term=query.strip(), types=kind, limit=limit, offset=offset)
        bucket = response.get("results", {}).get(kind, {})
        raw_items = bucket.get("data", [])
        if not isinstance(raw_items, list):
            raise RuntimeError("Search response unavailable")
        results = [result for item in raw_items if (result := search_item(item, kind)) is not None]
        next_uri = bucket.get("next")
        next_offset = None
        if isinstance(next_uri, str) and next_uri:
            next_values = parse_qs(urlsplit(next_uri).query).get("offset", [])
            parsed_offset = int(next_values[0]) if next_values and next_values[0].isdigit() else 0
            next_offset = parsed_offset if offset < parsed_offset <= 100000 else offset + len(raw_items)
            if next_offset <= offset or next_offset > 100000:
                next_offset = None
        state.update(results=results, has_more=next_offset is not None, next_offset=next_offset)
        message = f"在 {state['storefront'].upper()} 目录找到 {len(results)} 项结果。"
        if state["auth_invalid"]:
            message += " 当前使用公开目录；下载前请重新导入有效登录凭据。"
        elif state["network_failure"]:
            message += " 账户暂时无法验证，已使用公开目录；可稍后重试账户验证。"
        return done_result(message=message, **state)
    except UserError as error:
        return done_result(status="failed", message=str(error), **state)
    except Exception:
        state.update(network_failure=True, retryable=True)
        return done_result(status="failed", message="暂时无法读取 Apple Music 目录，请检查网络或稍后重试。", **state)
    finally:
        if api is not None:
            with suppress(Exception):
                await api.client.aclose()


def audio_valid(path: Path, required: str | None = None) -> bool:
    import mutagen
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        return False
    try:
        audio = mutagen.File(path)
        if audio is None or audio.info.length <= 0:
            return False
        codec = str(getattr(audio.info, "codec", ""))
        return required != "aac" or codec.startswith("mp4a")
    except Exception:
        return False


async def convert(source: Path, target: Path, format_: str, ffmpeg: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        raise UserError("目标文件已存在；为保留现有文件，本次未覆盖。")
    fd, temporary = tempfile.mkstemp(prefix=".converting-", suffix=target.suffix, dir=target.parent)
    os.close(fd)
    process = None
    codec = ["-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", "3"] if format_ == "mp3" else ["-c:a", "pcm_s24le"]
    try:
        process = await asyncio.create_subprocess_exec(
            ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", str(source),
            "-map", "0:a:0", "-map_metadata", "0", "-vn", *codec, temporary,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        await process.wait()
        if process.returncode or not audio_valid(Path(temporary)):
            raise UserError("音频转换失败，已保留获取成功的 AAC 原文件。")
        os.link(temporary, target)
        lyrics = source.with_suffix(".lrc")
        if lyrics.is_file():
            with target.with_suffix(".lrc").open("xb") as output, lyrics.open("rb") as input_:
                shutil.copyfileobj(input_, output)
    finally:
        if process is not None and process.returncode is None:
            with suppress(ProcessLookupError):
                process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=3)
            except asyncio.TimeoutError:
                with suppress(ProcessLookupError):
                    process.kill()
                await process.wait()
        Path(temporary).unlink(missing_ok=True)


class GamdlSession:
    def __init__(self, api, base, downloader, originals: Path):
        self.api, self.base, self.downloader, self.originals = api, base, downloader, originals
        self.completed = set()

    def media(self, url):
        # Parse each final media object independently so one preparation failure
        # cannot prematurely terminate the playlist generator.
        return self.base_interface.get_media_from_url(url)

    @property
    def base_interface(self):
        return self.downloader.base.interface

    async def download(self, media) -> Path:
        from gamdl.downloader import GamdlDownloaderMediaFileExistsError
        if media.error:
            raise media.error
        if (media.media_metadata or {}).get("type") not in {"songs", "library-songs"}:
            raise UserError("歌单中包含非歌曲内容，已跳过并计为未完成项目。")
        item = await self.downloader.parse_download_item(media)
        if item is None or not item.final_path:
            raise UserError("曲目未生成有效的下载目标。")
        target = Path(item.final_path).resolve()
        if not target.is_relative_to(self.originals):
            raise UserError("曲目目标路径无效，已停止该项目。")
        try:
            await self.downloader.download(item)
        except GamdlDownloaderMediaFileExistsError:
            if target not in self.completed:
                raise
        if not audio_valid(target, "aac"):
            raise UserError("下载结果未通过 AAC 音频文件检查。")
        self.completed.add(target)
        return target

    async def close(self):
        with suppress(Exception):
            await self.api.client.aclose()
        with suppress(Exception):
            await self.base.itunes_api.client.aclose()


async def build_session(cookie: Path, originals: Path, temporary: Path, ffmpeg: str):
    from gamdl.api import AppleMusicApi
    from gamdl.interface import (AppleMusicBaseInterface, AppleMusicInterface, AppleMusicSongInterface,
                                 AppleMusicMusicVideoInterface, AppleMusicUploadedVideoInterface)
    from gamdl.interface.enums import SongCodec
    from gamdl.downloader import (AppleMusicBaseDownloader, AppleMusicDownloader, AppleMusicSongDownloader,
                                  AppleMusicMusicVideoDownloader, AppleMusicUploadedVideoDownloader)
    token, _ = cookie_token(cookie)
    api = base = None
    try:
        api = await AppleMusicApi.create(media_user_token=token)
        if not api.active_subscription:
            raise UserError("当前登录未验证到有效的 Apple Music 订阅，请确认会员并重新导入登录。")
        base = await AppleMusicBaseInterface.create(apple_music_api=api, wrapper_api=None)
        interface = AppleMusicInterface(
            song=AppleMusicSongInterface(base, codec_priority=[SongCodec.AAC_WEB]),
            music_video=AppleMusicMusicVideoInterface(base),
            uploaded_video=AppleMusicUploadedVideoInterface(base),
            concurrency=1,
            disallowed_media_types=["music-videos", "library-music-videos", "uploaded-videos"])
        download_base = AppleMusicBaseDownloader(interface, output_path=str(originals),
                                                  temp_path=str(temporary), ffmpeg_path=ffmpeg, silent=True)
        downloader = AppleMusicDownloader(
            song=AppleMusicSongDownloader(download_base),
            music_video=AppleMusicMusicVideoDownloader(download_base),
            uploaded_video=AppleMusicUploadedVideoDownloader(download_base), overwrite=False)
        return GamdlSession(api, base, downloader, originals)
    except BaseException:
        if api:
            with suppress(Exception):
                await api.client.aclose()
        if base:
            with suppress(Exception):
                await base.itunes_api.client.aclose()
        raise


async def download(request: dict, emit, session_factory=build_session) -> dict:
    import imageio_ffmpeg
    url, format_, output, job_id = validate_download(request)
    cookie = path_argument(request, "cookie_path")
    cookie_token(cookie)  # Validate locally before any network request or output creation.
    originals = output / "Originals" / job_id
    destination = originals if format_ == "aac" else output / format_.upper() / job_id
    if originals.exists() or (destination != originals and destination.exists()):
        raise UserError("该任务的输出目录已存在，请创建新任务；现有文件不会被覆盖。")
    output.mkdir(parents=True, exist_ok=True)
    originals.mkdir(parents=True, exist_ok=False)
    destination.mkdir(parents=True, exist_ok=True)
    result_files, original_files, converted, reasons = [], [], {}, []
    seen, expected, succeeded, failed, incomplete = set(), 0, 0, 0, False
    session, cancelled = None, False
    temporary = Path(tempfile.mkdtemp(prefix=".applemusic-", dir=output))
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    emit({"event": "progress", "message": "正在验证订阅并读取曲目列表…", "completed": 0, "total": 0})
    try:
        session = await session_factory(cookie, originals, temporary, ffmpeg)
        async for media in session.media(url):
            metadata = media.media_metadata or {}
            kind = metadata.get("type")
            attributes = metadata.get("attributes", {})
            tracks = metadata.get("relationships", {}).get("tracks", {}).get("data", [])
            if kind in {"albums", "library-albums", "playlists", "library-playlists"}:
                expected = max(expected, len(tracks), int(attributes.get("trackCount", 0) or 0))
                if media.error:
                    incomplete = True
                    reason = safe_error(media.error)
                    reasons.append(reason)
                    emit({"event": "progress", "message": reason, "completed": len(seen), "total": expected})
                continue
            expected = max(expected, int(media.total or 0), (media.index + 1) if media.index is not None else 1)
            title = str(attributes.get("name", "曲目"))[:160].replace("\n", " ")
            if media.partial:
                emit({"event": "progress", "message": f"正在准备：{title}", "completed": len(seen), "total": expected})
                continue
            key = (media.index, media.media_id)
            if key in seen:
                continue
            seen.add(key)
            try:
                emit({"event": "progress", "message": f"正在获取：{title}", "completed": len(seen) - 1, "total": expected})
                source = (await session.download(media)).resolve()
                if not source.is_relative_to(originals) or not audio_valid(source, "aac"):
                    raise UserError("下载结果未通过本地音频检查。")
                if str(source) not in original_files:
                    original_files.append(str(source))
                target = source
                if format_ != "aac":
                    target = destination / source.relative_to(originals).with_suffix("." + format_)
                    if source not in converted:
                        emit({"event": "progress", "message": f"正在转换为 {format_.upper()}：{title}", "completed": len(seen) - 1, "total": expected})
                        await convert(source, target, format_, ffmpeg)
                        converted[source] = target
                if str(target) not in result_files:
                    result_files.append(str(target))
                succeeded += 1
                message = f"已完成：{title}"
            except Exception as error:
                failed += 1
                reason = safe_error(error)
                reasons.append(reason)
                message = f"未完成：{title}。{reason}"
            emit({"event": "progress", "message": message, "completed": len(seen), "total": expected})
    except asyncio.CancelledError:
        cancelled = True
    except Exception as error:
        incomplete = True
        reason = safe_error(error)
        reasons.append(reason)
        emit({"event": "progress", "message": reason, "completed": len(seen), "total": expected})
    finally:
        if session is not None:
            await session.close()
        shutil.rmtree(temporary, ignore_errors=True)
    missing = max(0, expected - len(seen))
    total = max(expected, len(seen))
    if cancelled:
        status, message = "cancelled", f"已取消；保留已完成的 {succeeded} 首及已获取的 AAC 原文件。"
    elif succeeded and not failed and not missing and not incomplete:
        status, message = "completed", f"已完成 {succeeded} 首。"
    elif succeeded:
        status, message = "partial", f"部分完成：成功 {succeeded} 首，失败 {failed + missing} 首。"
        if incomplete:
            message += "曲目列表未完整读取。"
    else:
        status, message = "failed", "未生成所选格式的完整音频文件。"
    if status in {"failed", "partial"}:
        message += " ".join(list(dict.fromkeys(reasons))[:2]) or "未找到可处理的歌曲，请检查链接和内容可用性。"
        if original_files:
            message += " 已保留获取成功的 AAC 原文件。"
    if format_ == "wav" and succeeded:
        message += " WAV 来自 AAC，转换不会提升音质。"
    return {"event": "done", "status": status, "message": message, "files": result_files,
            "output": str(destination), "original_files": original_files, "succeeded": succeeded,
            "failed": failed + missing, "total": total}


async def handle(request: dict, emit) -> dict:
    command = request.get("command")
    if command == "verify_account":
        return await verify_account(request)
    if command == "search":
        return await search_catalog(request)
    if command == "download":
        return await download(request, emit)
    result = {"event": "done", "status": "completed", "message": "", "files": [], "output": ""}
    if command == "import_cookies":
        private_cookie_import(path_argument(request, "source"), path_argument(request, "cookie_path"))
        return dict(result, valid=True, message="已导入 Apple Music 登录凭据；下载时会验证订阅与实际登录状态。")
    if command == "auth_status":
        try:
            cookie_token(path_argument(request, "cookie_path"))
            return dict(result, valid=True, message="已导入登录凭据；尚未在线验证订阅。")
        except (UserError, OSError):
            return dict(result, valid=False, message="尚未导入有效的 Apple Music 登录凭据。")
    if command == "self_test":
        import imageio_ffmpeg
        import gamdl.downloader
        import gamdl.interface
        import mutagen
        process = await asyncio.create_subprocess_exec(imageio_ffmpeg.get_ffmpeg_exe(), "-version",
                                                       stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        stdout, _ = await process.communicate()
        if process.returncode:
            raise UserError("内置音频转换器无法启动。")
        return dict(result, message="本地运行环境检查通过；未联网或读取登录凭据。", versions={
            "python": sys.version.split()[0], "gamdl": importlib.metadata.version("gamdl"),
            "ffmpeg": stdout.decode(errors="replace").splitlines()[0], "mutagen": mutagen.version_string})
    raise UserError("未知操作。")


def main() -> int:
    # Create the process group before imports, stdin reads or child processes.
    try:
        os.setsid()
    except OSError:
        if os.getpgrp() != os.getpid():
            return 2
    event_stream = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1, encoding="utf-8")
    with open(os.devnull, "w") as silent:
        os.dup2(silent.fileno(), 1)
        os.dup2(silent.fileno(), 2)
    logging.disable(logging.CRITICAL)
    def emit(event):
        event_stream.write(json.dumps(event, ensure_ascii=False) + "\n")
        event_stream.flush()
    async def run():
        current = asyncio.current_task()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, current.cancel)
        try:
            raw = sys.stdin.readline(1_048_577)
            request = json.loads(raw)
            if not isinstance(request, dict) or len(raw) > 1_048_576:
                raise UserError("请求格式不正确。")
            result = await handle(request, emit)
        except asyncio.CancelledError:
            result = {"event": "done", "status": "cancelled", "message": "已取消。", "files": [], "output": ""}
        except Exception as error:
            result = {"event": "done", "status": "failed", "message": safe_error(error), "files": [], "output": "", "valid": False}
        emit(result)
        return 0 if result["status"] == "completed" else 1
    try:
        return asyncio.run(run())
    finally:
        event_stream.close()


if __name__ == "__main__":
    sys.exit(main())
