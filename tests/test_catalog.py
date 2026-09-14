#!/usr/bin/env python3
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from catalog import (  # noqa: E402
    Catalog,
    CatalogError,
    context_item,
    duration_ms,
    map_items,
    thumbnail_url,
    track_item,
)


class CatalogTests(unittest.TestCase):
    def test_duration_parses_clock_and_seconds(self):
        self.assertEqual(duration_ms({"duration": "3:45"}), 225000)
        self.assertEqual(duration_ms({"duration": "1:02:03"}), 3723000)
        self.assertEqual(duration_ms({"duration_seconds": 90}), 90000)
        self.assertEqual(duration_ms({}), 0)

    def test_track_item_normalizes_song(self):
        item = track_item({
            "title": "Under the Bridge",
            "videoId": "GLvqBAudoEg",
            "artists": [{"name": "Red Hot Chili Peppers", "id": "UC123"}],
            "album": {"name": "Blood Sugar Sex Magik", "id": "MPREb_album"},
            "duration": "4:24",
            "thumbnails": [{"url": "https://img/small.jpg", "width": 60},
                           {"url": "https://img/large.jpg", "width": 544}],
            "likeStatus": "LIKE",
        })
        self.assertIsNotNone(item)
        self.assertEqual(item["type"], "track")
        self.assertEqual(item["kind"], "item")
        self.assertEqual(item["uri"], "ytm:track:GLvqBAudoEg")
        self.assertEqual(item["subtitle"], "Red Hot Chili Peppers")
        self.assertEqual(item["album"], "Blood Sugar Sex Magik")
        self.assertTrue(item["liked"])
        self.assertEqual(item["imageUrl"], "https://img/large.jpg")
        self.assertEqual(item["durationMs"], 264000)
        self.assertEqual(item["albumItem"]["type"], "album")

    def test_context_item_playlist(self):
        item = context_item({
            "title": "Liked Music",
            "playlistId": "LM",
            "count": 12,
        }, "playlist")
        self.assertEqual(item["type"], "playlist")
        self.assertEqual(item["kind"], "context")
        self.assertIn("12 songs", item["subtitle"])

    def test_map_items_skips_junk(self):
        rows = map_items([
            None,
            {"title": "Nope"},
            {"title": "Song", "videoId": "abcdefghijk"},
        ])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["videoId"], "abcdefghijk")

    def test_thumbnail_prefers_wide_image(self):
        url = thumbnail_url({
            "thumbnails": [
                {"url": "a", "width": 60},
                {"url": "b", "width": 226},
            ]
        })
        self.assertEqual(url, "b")




class SessionValidityTests(unittest.TestCase):
    """A signed-out session must never look like an empty library.

    YouTube answers an anonymous library request with an empty list rather
    than an error, and the catalog used to swallow every exception, so a dead
    session and a genuinely empty account produced the same blank UI.
    """

    class FakeYT:
        def __init__(self, *, signed_in: bool):
            self._signed_in = signed_in

        def get_account_info(self):
            if not self._signed_in:
                raise KeyError("Unable to find 'header'")
            return {"accountName": "Test User"}

        def get_library_playlists(self, limit=50):
            # Anonymous: empty, no exception. This is the trap.
            return [] if not self._signed_in else [{"title": "Mix", "playlistId": "PL1"}]

        def get_liked_songs(self, limit=50):
            if not self._signed_in:
                raise KeyError("Unable to find 'twoColumnBrowseResultsRenderer'")
            return {"tracks": [self._song()]}

        def get_library_songs(self, limit=50):
            return [] if not self._signed_in else [self._song()]

        @staticmethod
        def _song():
            return {"title": "Song", "videoId": "abc123", "duration_seconds": 100}

    def test_verify_session_accepts_live_account(self):
        cat = Catalog(self.FakeYT(signed_in=True))
        valid, name, err = cat.verify_session()
        self.assertTrue(valid)
        self.assertEqual(name, "Test User")
        self.assertEqual(err, "")

    def test_verify_session_rejects_dead_session(self):
        cat = Catalog(self.FakeYT(signed_in=False))
        valid, name, err = cat.verify_session()
        self.assertFalse(valid)
        self.assertEqual(name, "")
        self.assertIn("no longer valid", err)

    def test_library_raises_when_session_invalid(self):
        cat = Catalog(self.FakeYT(signed_in=False))
        cat.verify_session()
        # The anonymous backend returns [] with no error, so the old code
        # reported an empty playlist list. It must raise instead.
        for call in (cat.playlists, cat.library_songs, cat.liked, cat.history):
            with self.assertRaises(CatalogError):
                call()

    def test_library_returns_items_when_session_valid(self):
        cat = Catalog(self.FakeYT(signed_in=True))
        cat.verify_session()
        self.assertEqual(len(cat.playlists()), 1)
        self.assertEqual(len(cat.library_songs()), 1)
        self.assertEqual(len(cat.liked()), 1)

    def test_library_refuses_before_verification(self):
        cat = Catalog(self.FakeYT(signed_in=True))
        # Nothing has confirmed the session yet; answering now would be a guess.
        with self.assertRaises(CatalogError):
            cat.playlists()


if __name__ == "__main__":
    unittest.main()
