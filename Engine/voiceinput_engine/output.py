"""把识别结果写入剪贴板，并按设置向当前应用发送 Cmd+V。"""

from __future__ import annotations

import subprocess
import time


def copy_and_optionally_paste(text: str, auto_paste: bool) -> None:
    """剪贴板始终保留最终文本；自动粘贴失败时用户仍可手工 Cmd+V。"""
    subprocess.run(["/usr/bin/pbcopy"], input=text.encode("utf-8"), check=True)
    if not auto_paste:
        return

    # 直接使用 Quartz 注入 Cmd+V，避免 osascript 额外触发“自动化”权限。
    import Quartz

    time.sleep(0.05)
    key_down = Quartz.CGEventCreateKeyboardEvent(None, 0x09, True)
    key_up = Quartz.CGEventCreateKeyboardEvent(None, 0x09, False)
    Quartz.CGEventSetFlags(key_down, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventSetFlags(key_up, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, key_down)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, key_up)
