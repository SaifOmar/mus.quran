import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import time

from rangecache import RangeCache


def test_coalesce_and_contains(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    c.set_size("ar.alafasy", 1, 100, "audio/mpeg")
    c.write_range("ar.alafasy", 1, 0, b"hello world")
    assert c.get_cached_ranges("ar.alafasy", 1) == [(0, 11)]
    assert c.read_range("ar.alafasy", 1, 0, 11) == b"hello world"
    assert not c.has_full_file("ar.alafasy", 1)

    # Adjacent fill coalesces: [0,11) + [11,18) -> [0,18)
    c.write_range("ar.alafasy", 1, 11, b" second")
    assert c.get_cached_ranges("ar.alafasy", 1) == [(0, 18)]
    assert not c.has_full_file("ar.alafasy", 1)

    # Overlapping + spanning writes merge.
    c.write_range("ar.alafasy", 1, 0, b"0123456789")
    c.write_range("ar.alafasy", 1, 90, b"junk")
    c.write_range("ar.alafasy", 1, 50, b"x")
    assert c.get_cached_ranges("ar.alafasy", 1) == [(0, 18), (50, 51), (90, 94)]


def test_full_file(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    c.set_size("ar.alafasy", 2, 10, "audio/mpeg")
    assert not c.has_full_file("ar.alafasy", 2)
    c.write_range("ar.alafasy", 2, 0, b"0123456789")
    assert c.has_full_file("ar.alafasy", 2)
    assert c.get_total_bytes() == 10
    assert c.get_file_count() == 1


def test_write_bounds_rejected(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    c.set_size("ar.alafasy", 3, 10, "audio/mpeg")
    assert c.write_range("ar.alafasy", 3, 5, b"0123456789") is False  # 15 > size
    assert c.write_range("ar.alafasy", 3, 0, b"") is True


def test_sidecar_persists_across_reopen(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    c.set_size("ar.alafasy", 1, 1000, "audio/mpeg")
    c.write_range("ar.alafasy", 1, 0, b"a" * 500)

    c2 = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    assert c2.get_size("ar.alafasy", 1) == 1000
    assert c2.get_cached_ranges("ar.alafasy", 1) == [(0, 500)]
    assert c2.read_range("ar.alafasy", 1, 0, 100) == b"a" * 100


def test_size_mismatch_discards_ranges(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    c.set_size("ar.alafasy", 3, 1000, "audio/mpeg")
    c.write_range("ar.alafasy", 3, 0, b"a" * 300)

    dat = c.data_path("ar.alafasy", 3)
    with open(dat, "r+b") as f:
        f.truncate(500)

    c2 = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    assert c2.get_cached_ranges("ar.alafasy", 3) == []
    assert not c2.has_full_file("ar.alafasy", 3)


def test_corrupt_sidecar_treated_empty(tmp_path):
    rec_dir = tmp_path / "ar.alafasy"
    rec_dir.mkdir(mode=0o700)
    (rec_dir / "4.meta.json").write_text("{corrupt")
    c = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    assert c.get_cached_ranges("ar.alafasy", 4) == []
    assert c.get_size("ar.alafasy", 4) is None


def test_remove(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    c.set_size("ar.alafasy", 3, 64, "audio/mpeg")
    c.write_range("ar.alafasy", 3, 0, b"a" * 10)
    c.remove("ar.alafasy", 3)
    assert c.get_file_count() == 0
    assert not os.path.exists(c.data_path("ar.alafasy", 3))
    assert not os.path.exists(os.path.join(str(tmp_path), "ar.alafasy", "3.meta.json"))
    c.remove("ar.alafasy", 3)  # idempotent


def test_get_missing_ranges(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    c.set_size("ar.alafasy", 5, 100, "audio/mpeg")
    c.write_range("ar.alafasy", 5, 0, b"a" * 10)
    c.write_range("ar.alafasy", 5, 20, b"b" * 10)
    missing = c.get_missing_ranges("ar.alafasy", 5, 0, 100)
    assert missing == [(10, 20), (30, 100)]


def test_promote(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    c.set_size("ar.alafasy", 1, 12, "audio/mpeg")
    c.write_range("ar.alafasy", 1, 0, b"hello ")

    # Not full -> no promotion.
    dest = tmp_path / "data" / "ar.alafasy" / "1.mp3"
    assert c.promote("ar.alafasy", 1, str(dest), validate=False) == "notfull"
    assert not dest.exists()

    c.write_range("ar.alafasy", 1, 6, b"world!")
    assert c.has_full_file("ar.alafasy", 1)
    assert c.promote("ar.alafasy", 1, str(dest), validate=False) == "ok"
    assert dest.read_bytes() == b"hello world!"
    assert c.get_file_count() == 0

    # Second promote on missing entry -> notfull.
    assert c.promote("ar.alafasy", 1, str(dest), validate=False) == "notfull"


def test_evict_lru_by_mtime(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1000)
    for n in (1, 2, 3):
        c.set_size("ar.alafasy", n, 800, "audio/mpeg")
        c.write_range("ar.alafasy", n, 0, b"x")
    # Oldest first; budget 1000 keeps only the newest 800B.
    tm = time.time() - 1000
    for n in (1, 2):
        path = c.data_path("ar.alafasy", n)
        os.utime(path, (tm, tm))
    os.utime(c.data_path("ar.alafasy", 3), (time.time() - 200, time.time() - 200))

    c.evict_to_budget()
    assert not os.path.exists(c.data_path("ar.alafasy", 1))
    assert not os.path.exists(c.data_path("ar.alafasy", 2))
    assert os.path.exists(c.data_path("ar.alafasy", 3))


def test_evict_skips_active_fill(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1000)
    for n in (1, 2):
        c.set_size("ar.alafasy", n, 800, "audio/mpeg")
        c.write_range("ar.alafasy", n, 0, b"x")
    end_fill = c.begin_fill("ar.alafasy", 1)
    c.evict_to_budget()
    assert os.path.exists(c.data_path("ar.alafasy", 1))
    assert not os.path.exists(c.data_path("ar.alafasy", 2))
    end_fill()
    c.set_size("ar.alafasy", 2, 800, "audio/mpeg")
    c.write_range("ar.alafasy", 2, 0, b"x")
    os.utime(c.data_path("ar.alafasy", 1), (time.time() - 1000, time.time() - 1000))
    c.evict_to_budget()
    assert not os.path.exists(c.data_path("ar.alafasy", 1))
    assert os.path.exists(c.data_path("ar.alafasy", 2))


def test_evict_skips_stray_non_numeric_dat(tmp_path):
    # A stray .dat with a non-numeric name (not one of our entries) must not
    # crash eviction and must be left untouched.
    c = RangeCache(str(tmp_path), budget_bytes=100)
    c.set_size("ar.alafasy", 1, 800, "audio/mpeg")
    c.write_range("ar.alafasy", 1, 0, b"x")
    stray = tmp_path / "ar.alafasy" / "notes.dat"
    stray.write_bytes(b"not ours")

    c.evict_to_budget()  # must not raise
    assert not os.path.exists(c.data_path("ar.alafasy", 1))
    assert stray.exists()
    assert stray.read_bytes() == b"not ours"


def test_clear_wipes_cache_only(tmp_path):
    c = RangeCache(str(tmp_path), budget_bytes=1 << 30)
    c.set_size("ar.alafasy", 1, 100, "audio/mpeg")
    c.write_range("ar.alafasy", 1, 0, b"x" * 50)
    c.set_size("ar.alafasy", 2, 100, "audio/mpeg")
    c.write_range("ar.alafasy", 2, 0, b"y" * 100)
    keeps = tmp_path / "mp3leftover.mp3"
    keeps.write_bytes(b"legacy file")

    c.clear()
    assert c.get_total_bytes() == 0
    assert c.get_file_count() == 0
    assert not (tmp_path / "ar.alafasy").exists()
    assert keeps.exists()