// Optimized matcher benchmark, including candidate preparation cost.
// Run from the repository root:
// swiftc -O -parse-as-library md-preview/Features/FileSearch/FileSearchMatcher.swift \
//   scripts/bench/file-search-benchmark.swift -o /tmp/file-search-benchmark
// /usr/bin/time -l /tmp/file-search-benchmark
// Pass --unicode to exercise the Unicode fallback with the same file count.
import Foundation

@main
struct FileSearchBenchmark {
    static func main() {
        let unicode = CommandLine.arguments.contains("--unicode")
        let start = ContinuousClock.now
        let candidates = (0..<20_000).map {
            FileSearchMatcher.Candidate(relativePath:
                "docs/section-\($0 % 100)/\(unicode ? "Übersicht-🚀-" : "")document-\($0).md")
        }
        print("prepare 20,000 candidates: \(milliseconds(since: start)) ms")
        for query in ["md", "document-123", "docs/sec", "zzzz"] {
            var samples: [Double] = []
            var count = 0
            for _ in 0..<6 {
                let start = ContinuousClock.now
                count = FileSearchMatcher.rank(query: query, candidates: candidates).count
                samples.append(milliseconds(since: start))
            }
            samples.removeFirst() // Warm-up; report the median of five passes.
            samples.sort()
            print("\(query): \(String(format: "%.2f", samples[2])) ms; \(count) matches")
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}
