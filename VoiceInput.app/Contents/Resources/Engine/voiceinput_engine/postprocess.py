"""识别后的中英文语气词清理与标点归一化。"""

from __future__ import annotations

import re


_CHINESE_FILLERS = re.compile(r"(?:嗯+|呃+|额+|呣+)")
_CHINESE_DEMONSTRATIVES = re.compile(
    r"(^|[\s，,。！？!?；;：:、])(?:那个|这个)(?=[\s，,。！？!?；;：:、]|$)"
)
_EDGE_CHINESE_FILLERS = re.compile(
    r"(^|[\s，,。！？!?；;：:、])(?:啊+|呀+|诶+|欸+|哎+|唉+|呐+|哦+|喔+|噢+)"
    r"(?=[\s，,。！？!?；;：:、]|$)"
)
# 英文只删除用户确认的保守集合；like/well/you know 等可能有真实语义，绝不触碰。
_ENGLISH_FILLERS = re.compile(r"(?i)(?<![A-Za-z])(?:um+|uh+|erm+|er)(?![A-Za-z])")


def remove_fillers(text: str) -> str:
    """同时删除中英文独立语气词，并清理由此产生的重复空格和标点。"""
    result = _CHINESE_FILLERS.sub("", text)
    result = _CHINESE_DEMONSTRATIVES.sub(r"\1", result)
    result = _EDGE_CHINESE_FILLERS.sub(r"\1", result)
    result = _ENGLISH_FILLERS.sub("", result)
    result = re.sub(r"^[\s，,。！？!?；;：:、]+", "", result)
    result = re.sub(r"[，,、]{2,}", "，", result)
    result = re.sub(r"。{2,}", "。", result)
    result = re.sub(r"\s+([，。！？；：、,.!?;:])", r"\1", result)
    # Python 标准 re 不支持 \p{Han}，用明确的 CJK 范围实现相同规则。
    result = re.sub(r"([\u4e00-\u9fff])\s+([\u4e00-\u9fff])", r"\1\2", result)
    result = re.sub(r"\s{2,}", " ", result)
    return result.strip(" \t\r\n，,。")
