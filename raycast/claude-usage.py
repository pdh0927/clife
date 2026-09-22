#!/usr/bin/env python3
#
# Raycast script command. Add this folder in Raycast > Extensions > Scripts,
# then assign a hotkey to "Claude 사용량".
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Claude 사용량
# @raycast.mode silent
#
# Optional parameters:
# @raycast.icon 📊
# @raycast.packageName Clife
# @raycast.description 플랜 사용량 한도를 HUD로 표시 (메뉴바를 보지 않고)
#
# Reads the same endpoint the Clife menu bar app and Claude's own usage popup
# use. Stdlib only -- no pip, no jq.

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = "https://api.anthropic.com/api/oauth/usage"

# Shared with the Clife menu bar app, deliberately: both hit one rate limit, so
# whichever fetched last covers the other. A hotkey press refreshes the app's
# rings too, and vice versa. Same file, same freshness window, same atomic write.
CACHE = os.path.expanduser("~/Library/Caches/com.example.clife/usage.json")

# Pressing the hotkey means "tell me now", so this is an anti-spam floor and
# nothing more: only a second press within a few seconds reuses the last answer.
# The endpoint is rate limited hard enough that a burst still gets a 429, but a
# burst is double-tapping, not asking -- and a refusal costs one fast round trip
# while a stale number costs the whole point of pressing the key.
MAX_AGE = 5


def read_cache():
    try:
        age = time.time() - os.path.getmtime(CACHE)
        with open(CACHE) as f:
            return json.load(f), age
    except (OSError, ValueError):
        return None, None


def write_cache(payload):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f)
    # Atomic, so the app -- reading the same file -- never sees a partial write.
    os.replace(tmp, CACHE)


def access_token():
    """Claude Code's OAuth token. Read only -- refreshing is Claude Code's job."""
    out = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise RuntimeError("Claude Code 로그인 필요")
    return json.loads(out.stdout)["claudeAiOauth"]["accessToken"]


def fetch():
    request = urllib.request.Request(ENDPOINT, headers={
        "Authorization": f"Bearer {access_token()}",
        "anthropic-beta": "oauth-2025-04-20",
    })
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)


def label(limit):
    kind = limit.get("kind")
    if kind == "session":
        return "5시간"
    if kind == "weekly_all":
        return "주간"
    model = (limit.get("scope") or {}).get("model") or {}
    return model.get("display_name") or kind


def relative_reset(raw):
    if not raw:
        return None
    # "2026-09-20T09:10:00.606234+00:00" -- fromisoformat handles 6 fractional
    # digits and the +00:00 offset on 3.11+; strip the fraction for older ones.
    try:
        when = time.mktime(time.strptime(raw.split(".")[0], "%Y-%m-%dT%H:%M:%S")) - time.timezone
    except ValueError:
        return None
    minutes = int((when - time.time()) / 60)
    if minutes <= 0:
        return "곧 초기화"
    if minutes < 60:
        return f"{minutes}분 후 초기화"
    hours = minutes // 60
    return f"{hours}시간 후 초기화" if hours < 24 else f"{hours // 24}일 후 초기화"


def render(payload, age):
    limits = payload.get("limits") or []
    if not limits:
        return "사용량 한도 없음 (Pro/Max 구독 필요)"

    parts = [f"{label(l)} {l['percent']:.0f}%" for l in limits]
    session = next((l for l in limits if l.get("group") == "session"), limits[0])
    reset = relative_reset(session.get("resets_at"))
    if reset:
        parts.append(reset)
    if age is not None and age > MAX_AGE:
        parts.append(f"{int(age)}초 전 값")
    return "  ·  ".join(parts)


def main():
    cached, age = read_cache()
    if cached is not None and age < MAX_AGE:
        print(render(cached, None))
        return

    try:
        payload = fetch()
        write_cache(payload)
        print(render(payload, None))
    except Exception as error:
        # A failed refresh should still show something useful: the last known
        # numbers, labelled with their age, beat an error with no data in it.
        if isinstance(error, urllib.error.HTTPError) and error.code == 429:
            reason = "요청 제한"
        elif isinstance(error, urllib.error.HTTPError) and error.code in (401, 403):
            reason = "토큰 만료 · Claude Code 실행 시 갱신됨"
        else:
            reason = str(error) or "조회 실패"
        if cached is not None:
            print(f"{render(cached, age)}  ·  {reason}")
        else:
            print(reason)
            sys.exit(1)


if __name__ == "__main__":
    main()
