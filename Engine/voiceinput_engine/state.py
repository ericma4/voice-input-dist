"""把引擎运行状态以原子 JSON 快照发布给 Swift 前端。"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from datetime import datetime, timezone
from typing import Any

from .paths import STATE_PATH, ensure_directories


class StatePublisher:
    """小型文件 IPC：状态变化即写快照，录音音量最多约每 50ms 更新一次。"""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._state: dict[str, Any] = {
            "state": "starting",
            "message": "Starting…",
            "audio_level": 0.0,
            "last_text": "",
            "model_variant": "8bit",
            "language": "auto",
            "pid": os.getpid(),
        }

    def update(self, **changes: Any) -> None:
        with self._lock:
            if all(self._state.get(key) == value for key, value in changes.items()):
                return
            self._state.update(changes)
            self._state["updated_at"] = datetime.now(timezone.utc).isoformat()
            self._write_locked()

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._state)

    def _write_locked(self) -> None:
        ensure_directories()
        fd, temp_name = tempfile.mkstemp(
            dir=STATE_PATH.parent,
            prefix=".engine-",
            suffix=".json",
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(self._state, handle, ensure_ascii=False)
            os.replace(temp_name, STATE_PATH)
        except Exception:
            try:
                os.unlink(temp_name)
            except OSError:
                pass
            raise
