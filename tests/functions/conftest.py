from __future__ import annotations

import sys
from pathlib import Path

FUNCTIONS_ROOT = Path(__file__).resolve().parents[2] / "src" / "functions"
sys.path.insert(0, str(FUNCTIONS_ROOT))

