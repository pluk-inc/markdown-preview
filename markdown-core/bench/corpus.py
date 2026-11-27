"""The documents that the benchmarks measure.

Each one is made one time, with a fixed seed, and kept in
`markdown-core/build/bench/corpus`. So each run and each build reads the
same bytes, and the time to make a document is never in a measurement.
Change VERSION when a document changes: the old numbers are then of
another text.

    markdown-core/bench/corpus.py        # makes them all and lists them
"""
from __future__ import annotations

import random
import subprocess
from pathlib import Path

CORE = Path(__file__).resolve().parents[1]
SHORT = CORE / "bench" / "short.md"
FOLDER = CORE / "build" / "bench" / "corpus"
VERSION = 1
# The long document: the short one this many times, about 1 MB.
LONG_COPIES = 128
# The commit that the real documents are read from, so they never change.
REAL_COMMIT = "e5b33f1e"
REAL_FILES = ("markdown-core/AGENTS.md", "CHANGELOG.md", "README.md")

CONSONANTS = "b c d f g h j k l m n p r s t v w z ch sh th st tr pl".split()
VOWELS = "a e i o u ai ea ou".split()
# Words of other alphabets, so that a text has more than one font.
OTHER_WORDS = "αλφα βήτα γάμμα δέλτα слово текст книга страница naïve café über señor 🙂 ✅".split()


class Text:
    """Words and sentences from one seed."""

    def __init__(self, seed: int) -> None:
        self.random = random.Random(seed)

    def word(self) -> str:
        if self.random.random() < 0.02:
            return self.random.choice(OTHER_WORDS)
        syllables = self.random.choice((1, 1, 2, 2, 2, 3, 3, 4))
        return "".join(self.random.choice(CONSONANTS) + self.random.choice(VOWELS) for _ in range(syllables))

    def words(self, low: int, high: int) -> str:
        return " ".join(self.word() for _ in range(self.random.randint(low, high)))

    def inline(self) -> str:
        """Some words, sometimes with a style."""
        words = self.words(1, 4)
        kind = self.random.random()
        if kind < 0.05:
            return f"**{words}**"
        if kind < 0.10:
            return f"*{words}*"
        if kind < 0.14:
            return f"`{words}`"
        if kind < 0.17:
            return f"[{words}](https://example.com/{self.word()})"
        if kind < 0.18:
            return f"~~{words}~~"
        return words

    def sentence(self) -> str:
        text = " ".join(self.inline() for _ in range(self.random.randint(2, 7)))
        return text[0].upper() + text[1:] + self.random.choice(". . . ? !".split())

    def paragraph(self) -> str:
        return " ".join(self.sentence() for _ in range(self.random.randint(1, 6)))


def prose(target_bytes: int, seed: int = 1) -> str:
    """Text of each block kind in an order that does not repeat: no word,
    line, or block is the same as one before it by design, so the caches of
    the text system and of the glyphs do not have all of it after the first
    screen."""
    text = Text(seed)
    pick = text.random
    blocks: list[str] = []
    size = 0
    while size < target_bytes:
        kind = pick.random()
        if kind < 0.10:
            block = "#" * pick.randint(1, 4) + " " + text.words(2, 6)
        elif kind < 0.55:
            block = text.paragraph()
        elif kind < 0.65:
            block = "\n".join(
                "  " * pick.randint(0, 2) + pick.choice(("- ", "- ", "1. ", "- [ ] ", "- [x] ")) + text.sentence()
                for _ in range(pick.randint(2, 9))
            )
        elif kind < 0.72:
            block = "\n".join("> " + text.sentence() for _ in range(pick.randint(1, 4)))
        elif kind < 0.82:
            lines = ("    " * pick.randint(0, 3) + text.words(1, 8) for _ in range(pick.randint(3, 30)))
            block = "```" + pick.choice(("", "swift", "python", "sh")) + "\n" + "\n".join(lines) + "\n```"
        elif kind < 0.90:
            columns = pick.randint(2, 6)
            rows = ["| " + " | ".join(text.words(1, 3) for _ in range(columns)) + " |" for _ in range(pick.randint(2, 12))]
            rows.insert(1, "|" + " --- |" * columns)
            block = "\n".join(rows)
        elif kind < 0.93:
            block = "---"
        else:
            block = text.paragraph() + "  \n" + text.sentence()
        blocks.append(block)
        size += len(block.encode()) + 2
    return "\n\n".join(blocks) + "\n"


def cjk(target_bytes: int, seed: int = 2) -> str:
    """Chinese and Japanese text from 3,000 characters, the number that a
    real text of this kind uses: many glyphs that are new on each screen."""
    pick = random.Random(seed)
    han = [chr(code) for code in pick.sample(range(0x4E00, 0x9FA6), 3000)]
    kana = [chr(code) for code in range(0x3041, 0x3094)] + [chr(code) for code in range(0x30A1, 0x30F7)]
    blocks: list[str] = []
    size = 0
    while size < target_bytes:
        if pick.random() < 0.08:
            block = "## " + "".join(pick.choices(han, k=pick.randint(3, 10)))
        else:
            sentences = []
            for _ in range(pick.randint(1, 6)):
                letters = pick.choices(han, k=pick.randint(8, 40)) + pick.choices(kana, k=pick.randint(0, 12))
                pick.shuffle(letters)
                sentences.append("".join(letters) + pick.choice("。。、！？"))
            block = "".join(sentences)
        blocks.append(block)
        size += len(block.encode()) + 2
    return "\n\n".join(blocks) + "\n"


def table(rows: int, seed: int = 3) -> str:
    """One table: the core lays a table out in one step."""
    text = Text(seed)
    lines = ["| " + " | ".join(text.words(1, 3) for _ in range(6)) + " |" for _ in range(rows + 1)]
    lines.insert(1, "|" + " --- |" * 6)
    return "# " + text.words(2, 4) + "\n\n" + "\n".join(lines) + "\n"


def paragraph(target_bytes: int, seed: int = 4) -> str:
    """One paragraph with no empty line: the core lays a paragraph out in
    one step."""
    text = Text(seed)
    lines: list[str] = []
    size = 0
    while size < target_bytes:
        lines.append(text.sentence())
        size += len(lines[-1].encode()) + 1
    return "\n".join(lines) + "\n"


def real() -> str:
    """Documents of this repository as they were at one commit."""
    parts = []
    for name in REAL_FILES:
        shown = subprocess.run(["git", "-C", CORE, "show", f"{REAL_COMMIT}:{name}"], capture_output=True, text=True)
        if shown.returncode != 0:
            raise RuntimeError(f"cannot read {name} at {REAL_COMMIT}: the history of the repository is not here")
        parts.append(shown.stdout)
    return "\n\n".join(parts)


# In the order of a table. The first two are the ones that BENCHMARKS.md
# has recorded since the first row.
MAKERS = {
    "short": lambda: SHORT.read_text(),
    "long": lambda: "\n\n".join([SHORT.read_text()] * LONG_COPIES),
    "prose": lambda: prose(1_000_000),
    "cjk": lambda: cjk(300_000),
    "table": lambda: table(2000),
    "paragraph": lambda: paragraph(60_000),
    "real": real,
}
NAMES = tuple(MAKERS)


def document(name: str) -> Path:
    """The file of a document, made when it is not there yet."""
    path = FOLDER / f"{name}-v{VERSION}.md"
    # The short one is a file of the repository: always the one of now.
    if name == "short" or not path.exists():
        FOLDER.mkdir(parents=True, exist_ok=True)
        path.write_text(MAKERS[name](), encoding="utf-8")
    return path


def documents(names: str) -> list[tuple[str, Path]]:
    """The documents of a list such as "short,long", or of "all"."""
    chosen = NAMES if names == "all" else tuple(names.split(","))
    unknown = [name for name in chosen if name not in MAKERS]
    if unknown:
        raise SystemExit(f"no document {', '.join(unknown)}; the documents are: {', '.join(NAMES)}")
    return [(name, document(name)) for name in chosen]


if __name__ == "__main__":
    for name, path in documents("all"):
        print(f"{name:10} {path.stat().st_size / 1024:8.0f} KB  {path}")
