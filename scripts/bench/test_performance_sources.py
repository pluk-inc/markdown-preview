import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from run_performance import prepare_sources


class PerformanceSourceTests(unittest.TestCase):
    def snapshot(self, root, name):
        snapshot = root / name
        helpers = snapshot / 'tests/swift-tests/Sources/MarkdownHelpers'
        helpers.mkdir(parents=True)
        self.link(snapshot, 'EditorHTML.swift', 'md-preview/EditorHTML.swift', 'editor')
        (helpers / 'Stub.swift').write_text(name)
        return snapshot

    def link(self, snapshot, name, target, text):
        production = snapshot / target
        production.parent.mkdir(parents=True, exist_ok=True)
        production.write_text(text)
        helper = snapshot / 'tests/swift-tests/Sources/MarkdownHelpers' / name
        helper.symlink_to('../../../../' + target)

    def test_source_additions_removals_moves_and_stubs_are_revision_local(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = self.snapshot(root, 'base')
            head = self.snapshot(root, 'head')
            self.link(base, 'Removed.swift', 'md-preview/Removed.swift', 'removed')
            self.link(base, 'Moved.swift', 'md-preview/Old.swift', 'old')
            self.link(head, 'Moved.swift', 'md-preview/New.swift', 'new')
            self.link(head, 'Added.swift', 'md-preview/Added.swift', 'added')
            # The checkout running the benchmark can have a different source set.
            with patch('run_performance.ROOT', head):
                prepare_sources(base, root / 'base-sources')
                prepare_sources(head, root / 'head-sources')
            for label, expected in [('base', {'Removed.swift', 'Moved.swift', 'EditorHTML.swift', 'Stub.swift'}),
                                    ('head', {'Added.swift', 'Moved.swift', 'EditorHTML.swift', 'Stub.swift'})]:
                sources = root / (label + '-sources')
                self.assertEqual({p.name for p in sources.iterdir()}, expected)
                self.assertEqual((sources / 'Stub.swift').read_text(), label)
                self.assertEqual((sources / 'Moved.swift').read_text(), 'old' if label == 'base' else 'new')

    def test_broken_production_link_is_not_silently_skipped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = self.snapshot(root, 'base')
            helpers = snapshot / 'tests/swift-tests/Sources/MarkdownHelpers'
            (helpers / 'Missing.swift').symlink_to('../../../../md-preview/Missing.swift')
            with self.assertRaisesRegex(ValueError, 'Production source missing'):
                prepare_sources(snapshot, root / 'sources')

    def test_pre_extraction_baseline_keeps_legacy_editor_adapter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = self.snapshot(root, 'base')
            (snapshot / 'tests/swift-tests/Sources/MarkdownHelpers/EditorHTML.swift').unlink()
            with patch('run_performance.legacy_editor', return_value='legacy editor') as adapter:
                prepare_sources(snapshot, root / 'sources')
            adapter.assert_called_once_with(snapshot.resolve())
            self.assertEqual((root / 'sources/EditorHTML.swift').read_text(), 'legacy editor')
