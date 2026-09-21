"""Exercise the probe's actual readiness scripts with delayed DOM/image promises."""
import json
from pathlib import Path
import re
import subprocess
import unittest


class BenchmarkReadinessTests(unittest.TestCase):
    def test_delayed_missing_replaced_and_broken_images(self):
        source = (Path(__file__).resolve().parents[2] / "tests/performance/Benchmark.swift").read_text()
        load = source.split("    func load(", 1)[1].split("    func editorEdits(", 1)[0]
        scripts = re.findall(r'callAsyncJavaScript\("""\n(.*?)\n\s*"""', load, re.S)
        self.assertEqual(len(scripts), 2)
        program = "const scripts = " + json.dumps(scripts) + ";\n" + r'''
const assert = require('node:assert/strict');
const initialize = new Function('isEditor', 'media', scripts[0]);
const poll = new Function('isEditor', 'media', scripts[1]);
let images = [], rootExists = true, pending = 0;
const root = {textContent: 'fixture', querySelectorAll: () => images, querySelector: () => ({})};
global.window = {__benchFrame: () => pending};
global.document = {fonts: {ready: Promise.resolve()}, visibilityState: 'visible',
    querySelector: () => rootExists ? root : null};
function image() {
    let resolve, reject, calls = 0;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    return {decode: () => { calls++; return promise; }, resolve, reject, get calls() { return calls; }};
}
(async () => {
    initialize(true, true);
    await Promise.resolve();
    // Navigation can finish before the root or the image widget appears.
    rootExists = false;
    assert.equal(poll(true, true), false);
    rootExists = true;
    for (let i = 0; i < 10; i++) assert.equal(poll(true, true), false);
    const first = image();
    images = [first];
    assert.equal(poll(true, true), false);
    assert.equal(poll(true, true), false);
    assert.equal(first.calls, 1);
    first.resolve();
    await Promise.resolve();
    assert.equal(poll(true, true), true);
    const replacement = image();
    images = [replacement];
    assert.equal(poll(true, true), false);
    replacement.resolve();
    await Promise.resolve();
    assert.equal(poll(true, true), true);
    images = [first, replacement];
    assert.equal(poll(true, true), false);
    images = [];
    assert.equal(poll(true, true), false);
    assert.equal(poll(false, false), true);
    pending = 1;
    assert.equal(poll(false, false), false);
    pending = 0;
    const broken = image();
    images = [broken];
    assert.equal(poll(true, true), false);
    broken.reject(new Error('decode failed'));
    await Promise.resolve();
    await Promise.resolve();
    assert.throws(() => poll(true, true), /decode failed/);
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
        result = subprocess.run(["node", "-e", program], text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
