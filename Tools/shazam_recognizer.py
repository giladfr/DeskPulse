#!/usr/bin/env python3
"""Small JSON-only bridge between DeskPulse and ShazamIO."""

import asyncio
import json
import sys

from shazamio import Shazam


async def recognize(path: str) -> None:
    response = await Shazam().recognize(path)
    track = response.get("track") or {}
    images = track.get("images") or {}
    result = {
        "title": track.get("title"),
        "artist": track.get("subtitle"),
        "artworkURL": images.get("coverarthq") or images.get("coverart"),
        "shazamURL": track.get("url"),
    }
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(json.dumps({"error": "Expected an audio file path"}))
        raise SystemExit(2)
    asyncio.run(recognize(sys.argv[1]))
