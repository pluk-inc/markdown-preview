"""The two documents that both benchmarks measure, so their tables compare."""
from pathlib import Path

CORE = Path(__file__).resolve().parents[1]
SHORT = CORE / "bench" / "short.md"
# The long document: the short one this many times, about 1 MB.
LONG_COPIES = 128


def write_long(path: Path) -> Path:
    path.write_text("\n\n".join([SHORT.read_text()] * LONG_COPIES))
    return path
