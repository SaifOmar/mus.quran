import json
import os
import threading
import time


class RangeCache:
    """Sparse range cache with .dat file + .meta.json sidecar.

    Format:
      <cache_dir>/<reciter>/<surah>.dat      # sparse file (fallocate), umask 077
      <cache_dir>/<reciter>/<surah>.meta.json # {size, content_type, fetched_ranges, etag, updated_at}

    Write-order invariant: write bytes -> merge interval -> persist sidecar.
    Crash can never claim unflushed bytes.
    """

    def __init__(self, cache_dir: str, budget_bytes: int = 500 * 1024 * 1024):
        self.cache_dir = os.path.abspath(cache_dir)
        self.budget_bytes = budget_bytes
        self._lock = threading.RLock()
        self._file_locks = {}  # (reciter, surah) -> threading.RLock
        self._inflight = {}    # (reciter, surah) -> set of waiter IDs
        self._active_fills = {}  # (reciter, surah) -> count

    def _cache_path(self, reciter: str, surah: int) -> str:
        return os.path.join(self.cache_dir, reciter, f"{surah}.dat")

    def _meta_path(self, reciter: str, surah: int) -> str:
        return os.path.join(self.cache_dir, reciter, f"{surah}.meta.json")

    def _ensure_dir(self, reciter: str):
        path = os.path.join(self.cache_dir, reciter)
        os.makedirs(path, mode=0o700, exist_ok=True)

    def _get_lock(self, reciter: str, surah: int) -> threading.RLock:
        key = (reciter, surah)
        with self._lock:
            if key not in self._file_locks:
                self._file_locks[key] = threading.RLock()
            return self._file_locks[key]

    def _load_meta(self, reciter: str, surah: int) -> dict | None:
        path = self._meta_path(reciter, surah)
        if not os.path.exists(path):
            return None
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            return None

    def _save_meta(self, reciter: str, surah: int, meta: dict):
        path = self._meta_path(reciter, surah)
        tmp_path = path + ".tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(meta, f)
        os.chmod(tmp_path, 0o600)
        os.rename(tmp_path, path)

    def _coalesce_ranges(self, ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
        """Merge overlapping/adjacent ranges. Input: list of [start, end) half-open."""
        if not ranges:
            return []
        sorted_ranges = sorted(ranges, key=lambda x: x[0])
        merged = [list(sorted_ranges[0])]
        for start, end in sorted_ranges[1:]:
            if start <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], end)
            else:
                merged.append([start, end])
        return [tuple(r) for r in merged]

    def has_full_file(self, reciter: str, surah: int) -> bool:
        """Check if the entire file is cached."""
        meta = self._load_meta(reciter, surah)
        if not meta:
            return False
        size = meta.get("size", 0)
        ranges = meta.get("fetched_ranges", [])
        if not ranges or self._size_mismatch(reciter, surah, meta):
            return False
        coalesced = self._coalesce_ranges(ranges)
        return coalesced == [(0, size)]

    def get_cached_ranges(self, reciter: str, surah: int) -> list[tuple[int, int]]:
        """Get coalesced cached ranges for a file."""
        meta = self._load_meta(reciter, surah)
        if not meta:
            return []
        if self._size_mismatch(reciter, surah, meta):
            return []
        ranges = meta.get("fetched_ranges", [])
        return self._coalesce_ranges(ranges)

    def _size_mismatch(self, reciter: str, surah: int, meta: dict) -> bool:
        """True if the .dat on disk disagrees with the sidecar size.

        Mirrors Go's reopen check: a truncation/crash that lost writes must
        never let the sidecar claim bytes it did not persist.
        """
        dat_path = self._cache_path(reciter, surah)
        try:
            actual = os.path.getsize(dat_path)
        except OSError:
            return False
        return actual != meta.get("size", 0)

    def get_size(self, reciter: str, surah: int) -> int | None:
        """Get total file size from sidecar."""
        meta = self._load_meta(reciter, surah)
        if not meta:
            return None
        return meta.get("size")

    def set_size(self, reciter: str, surah: int, size: int, content_type: str, etag: str = ""):
        """Initialize a new cache entry with known size."""
        self._ensure_dir(reciter)
        meta = {
            "size": size,
            "content_type": content_type,
            "fetched_ranges": [],
            "etag": etag,
            "updated_at": time.time(),
        }
        self._save_meta(reciter, surah, meta)
        # Preallocate sparse file
        dat_path = self._cache_path(reciter, surah)
        if not os.path.exists(dat_path):
            try:
                with open(dat_path, "wb") as f:
                    f.truncate(size)
            except OSError:
                pass  # fallocate may fail on some filesystems

    def write_range(self, reciter: str, surah: int, offset: int, data: bytes) -> bool:
        """Write data at offset. Returns True if successful.

        Maintains write-order invariant: write bytes -> merge interval -> persist sidecar.
        """
        lock = self._get_lock(reciter, surah)
        with lock:
            meta = self._load_meta(reciter, surah)
            if not meta:
                return False
            size = meta.get("size", 0)
            if offset + len(data) > size:
                return False

            dat_path = self._cache_path(reciter, surah)
            try:
                with open(dat_path, "r+b") as f:
                    f.seek(offset)
                    f.write(data)
                    f.flush()
                    os.fsync(f.fileno())
            except OSError:
                return False

            # Merge interval after successful write
            ranges = meta.get("fetched_ranges", [])
            ranges.append((offset, offset + len(data)))
            meta["fetched_ranges"] = self._coalesce_ranges(ranges)
            meta["updated_at"] = time.time()
            self._save_meta(reciter, surah, meta)
            return True

    def read_range(self, reciter: str, surah: int, offset: int, length: int) -> bytes | None:
        """Read cached data at offset. Returns bytes or None if not cached."""
        lock = self._get_lock(reciter, surah)
        with lock:
            ranges = self.get_cached_ranges(reciter, surah)
            # Check if range is fully covered
            for start, end in ranges:
                if offset >= start and offset + length <= end:
                    dat_path = self._cache_path(reciter, surah)
                    try:
                        with open(dat_path, "rb") as f:
                            f.seek(offset)
                            return f.read(length)
                    except OSError:
                        return None
            return None

    def get_missing_ranges(self, reciter: str, surah: int, start: int, end: int) -> list[tuple[int, int]]:
        """Get missing ranges within [start, end)."""
        cached = self.get_cached_ranges(reciter, surah)
        missing = []
        current = start
        for cs, ce in cached:
            if ce <= start:
                continue
            if cs >= end:
                break
            if current < cs:
                missing.append((current, min(cs, end)))
            current = max(current, ce)
            if current >= end:
                break
        if current < end:
            missing.append((current, end))
        return missing

    def data_path(self, reciter: str, surah: int) -> str:
        """Absolute path of the sparse cache file for a reciter/surah."""
        return self._cache_path(reciter, surah)

    def remove(self, reciter: str, surah: int):
        """Delete .dat and .meta.json pair (public)."""
        self._delete_entry(reciter, surah)

    def clear(self):
        """Full wipe: delete every .dat / .meta.json / stray .tmp in the cache."""
        with self._lock:
            if not os.path.isdir(self.cache_dir):
                return
            for reciter in os.listdir(self.cache_dir):
                rec_dir = os.path.join(self.cache_dir, reciter)
                if not os.path.isdir(rec_dir) or os.path.islink(rec_dir):
                    continue
                try:
                    for fname in os.listdir(rec_dir):
                        if fname.endswith((".dat", ".meta.json", ".tmp")):
                            os.remove(os.path.join(rec_dir, fname))
                    try:
                        os.rmdir(rec_dir)
                    except OSError:
                        pass  # left non-empty; not ours to remove
                except OSError:
                    pass

    def promote(self, reciter: str, surah: int, dest_path: str, validate: bool = True) -> str:
        """Atomically promote a fully-cached file to destination (data_dir).

        Returns one of:
          "ok"       promoted; cache entry removed
          "notfull"  file not fully cached (no-op)
          "invalid"  media validation failed; cache entry deleted (cooldown)
          "error"    filesystem error during promotion (cache kept)

        When validate=False the caller is responsible for having validated the
        data first (mirrors handler.maybePromote's validate-then-promote split
        while keeping the two-rename atomic move in one place).
        """
        lock = self._get_lock(reciter, surah)
        with lock:
            if not self.has_full_file(reciter, surah):
                return "notfull"
            dat_path = self._cache_path(reciter, surah)
            if not os.path.exists(dat_path):
                return "notfull"

            if validate:
                from mediavalidate import validate_media_file
                if not validate_media_file(dat_path):
                    self._delete_entry(reciter, surah)
                    return "invalid"

            try:
                os.makedirs(os.path.dirname(dest_path), mode=0o700, exist_ok=True)
                tmp_dest = dest_path + ".tmp"
                os.rename(dat_path, tmp_dest)
                os.rename(tmp_dest, dest_path)
            except OSError:
                return "error"

            self._delete_entry(reciter, surah)
            return "ok"

    def _delete_entry(self, reciter: str, surah: int):
        """Delete .dat and .meta.json pair."""
        for p in (self._cache_path(reciter, surah), self._meta_path(reciter, surah)):
            try:
                os.remove(p)
            except OSError:
                pass

    def begin_fill(self, reciter: str, surah: int):
        """Mark a (reciter, surah) origin fill as in-flight. Returns end_fill()."""
        key = (reciter, surah)
        with self._lock:
            self._active_fills[key] = self._active_fills.get(key, 0) + 1

        def end_fill():
            with self._lock:
                self._active_fills[key] -= 1
                if self._active_fills[key] <= 0:
                    self._active_fills.pop(key, None)
        return end_fill

    def _is_active(self, key):
        with self._lock:
            return self._active_fills.get(key, 0) > 0

    def get_total_bytes(self) -> int:
        """Total bytes used by cache (.dat files only, not sidecars)."""
        total = 0
        if not os.path.isdir(self.cache_dir):
            return 0
        for reciter in os.listdir(self.cache_dir):
            rec_dir = os.path.join(self.cache_dir, reciter)
            if not os.path.isdir(rec_dir):
                continue
            for fname in os.listdir(rec_dir):
                if fname.endswith(".dat"):
                    fpath = os.path.join(rec_dir, fname)
                    try:
                        total += os.path.getsize(fpath)
                    except OSError:
                        pass
        return total

    def get_file_count(self) -> int:
        """Number of cached files (.dat files)."""
        count = 0
        if not os.path.isdir(self.cache_dir):
            return 0
        for reciter in os.listdir(self.cache_dir):
            rec_dir = os.path.join(self.cache_dir, reciter)
            if not os.path.isdir(rec_dir):
                continue
            for fname in os.listdir(rec_dir):
                if fname.endswith(".dat"):
                    count += 1
        return count

    def evict_to_budget(self):
        """Evict LRU entries to stay under budget.

        Skips files with in-flight origin fills (mirrors Go's EvictToBudget).
        """
        files = []
        if not os.path.isdir(self.cache_dir):
            return
        for reciter in os.listdir(self.cache_dir):
            rec_dir = os.path.join(self.cache_dir, reciter)
            if not os.path.isdir(rec_dir):
                continue
            for fname in os.listdir(rec_dir):
                if not fname.endswith(".dat"):
                    continue
                try:
                    surah = int(fname[: -len(".dat")])
                except ValueError:
                    continue  # stray/unrelated .dat; not ours
                if surah < 1 or surah > 114:
                    continue
                fpath = os.path.join(rec_dir, fname)
                if self._is_active((reciter, surah)):
                    continue
                try:
                    st = os.stat(fpath)
                    files.append((st.st_mtime, fpath, reciter, surah))
                except OSError:
                    pass

        files.sort(key=lambda x: x[0])  # oldest first
        total = self.get_total_bytes()
        for _, fpath, reciter, surah in files:
            if total <= self.budget_bytes:
                break
            total -= self._file_size(fpath)
            self._delete_entry(reciter, surah)

    @staticmethod
    def _file_size(path):
        try:
            return os.path.getsize(path)
        except OSError:
            return 0

    def set_budget(self, budget_bytes: int):
        self.budget_bytes = budget_bytes


class SingleFlight:
    """Deduplication for concurrent origin fills (Go singleflight semantics).

    Keyed by (reciter, surah). Only one fetch per key; waiters block and
    share the result. Caller disconnect aborts only when it is the last waiter.
    """

    def __init__(self):
        self._lock = threading.RLock()
        self._inflight = {}  # key -> {"result":..., "exc":..., "waiters": int, "cv": cond}

    def do(self, key, fn, abort_if_last=False):
        """Execute fn(key) once; concurrent callers for the same key share the result.

        Returns the shared result (re-raises the shared exception on failure).
        """
        with self._lock:
            entry = self._inflight.get(key)
            if entry is None:
                entry = {
                    "result": None,
                    "exc": None,
                    "waiters": 1,
                    "cv": threading.Condition(self._lock),
                    "done": False,
                }
                self._inflight[key] = entry
                is_leader = True
            else:
                entry["waiters"] += 1
                is_leader = False

        if is_leader:
            try:
                result = fn(key)
            except Exception as e:  # noqa: BLE001 - stored, re-raised for waiters
                result = None
                entry["exc"] = e
            with self._lock:
                entry["result"] = result
                entry["done"] = True
                entry["cv"].notify_all()

        with self._lock:
            cv = entry["cv"]
            while not entry["done"]:
                cv.wait()
            entry["waiters"] -= 1
            if entry["waiters"] <= 0:
                self._inflight.pop(key, None)
            exc = entry["exc"]
            result = entry["result"]

        if exc is not None:
            raise exc
        return result