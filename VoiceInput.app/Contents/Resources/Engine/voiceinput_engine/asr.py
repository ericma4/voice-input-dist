"""Qwen3-ASR MLX 的最小常驻封装，调用方式与 CapsWriter macOS 后端一致。"""

from __future__ import annotations

import numpy as np

from .config import SUPPORTED_LANGUAGES
from .paths import model_is_complete, model_path


class ModelMissingError(RuntimeError):
    """选定模型尚未安装。"""


class QwenASREngine:
    """持有一个 mlx_qwen3_asr.Session，使模型权重在应用运行期间常驻。"""

    def __init__(self, variant: str) -> None:
        if not model_is_complete(variant):
            raise ModelMissingError(f"Qwen3-ASR {variant} model is not installed")
        # 延迟导入避免 doctor、模型下载和单元测试无意初始化 Metal。
        from mlx_qwen3_asr import Session

        self.variant = variant
        self.session = Session(model=str(model_path(variant)))

    def transcribe(self, samples: np.ndarray, language: str, context: str = "") -> str:
        """接受 16 kHz 单声道 float32；语言 auto 时把 None 交给模型自行判断。"""
        normalized = np.asarray(samples, dtype=np.float32).reshape(-1)
        if normalized.size < 1600:
            return ""
        mapped_language = SUPPORTED_LANGUAGES.get(language)
        result = self.session.transcribe(
            (normalized, 16000),
            context=context,
            language=mapped_language,
            return_timestamps=False,
            max_new_tokens=None,
            verbose=False,
        )
        return (result.text or "").strip()

    def close(self) -> None:
        """释放模型引用并尽量归还 MLX 缓存。"""
        self.session = None
        try:
            import mlx.core as mx

            clear_cache = getattr(mx, "clear_cache", None)
            if callable(clear_cache):
                clear_cache()
        except Exception:
            pass
