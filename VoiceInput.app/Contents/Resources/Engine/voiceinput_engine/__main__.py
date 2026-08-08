"""允许 `python -m voiceinput_engine` 直接进入备用 CLI。"""

from .cli import main

raise SystemExit(main())
