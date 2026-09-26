import Foundation

/// Runs an async transform over a sequence with a hard cap on in-flight work.
///
/// The scan must never spawn one `Task` per asset — a 10,000-photo library would
/// create 10,000 concurrent image requests and exhaust memory long before the
/// first result lands. This keeps exactly `limit` operations in flight, starting
/// a new one only as another finishes.
///
/// Results are returned in completion order, not input order; callers that need
/// ordering sort afterwards.
enum BoundedConcurrency {

    /// A sensible default for image-decoding work: enough to saturate the
    /// hardware, low enough to keep the peak thumbnail working set small.
    static var defaultLimit: Int {
        max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Maps `items` through `transform`, at most `limit` at a time.
    /// `onProgress` fires once per completed item.
    static func map<Input: Sendable, Output: Sendable>(
        _ items: [Input],
        limit: Int = defaultLimit,
        transform: @escaping @Sendable (Input) async -> Output?,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async -> [Output] {
        guard !items.isEmpty else { return [] }
        let cap = max(1, limit)
        var results: [Output] = []
        results.reserveCapacity(items.count)
        var completed = 0

        await withTaskGroup(of: Output?.self) { group in
            var next = 0
            // Prime the pump up to the cap.
            while next < min(cap, items.count) {
                let item = items[next]
                group.addTask { await transform(item) }
                next += 1
            }
            // For each completion, enqueue exactly one replacement.
            while let finished = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                if let value = finished { results.append(value) }
                completed += 1
                onProgress?(completed)
                if next < items.count {
                    let item = items[next]
                    group.addTask { await transform(item) }
                    next += 1
                }
            }
        }
        return results
    }

    /// Same bounded traversal, but streams each result as it completes so the UI
    /// can render partial output mid-scan.
    static func stream<Input: Sendable, Output: Sendable>(
        _ items: [Input],
        limit: Int = defaultLimit,
        transform: @escaping @Sendable (Input) async -> Output?,
        handle: @Sendable (Output) async -> Void
    ) async {
        guard !items.isEmpty else { return }
        let cap = max(1, limit)
        await withTaskGroup(of: Output?.self) { group in
            var next = 0
            while next < min(cap, items.count) {
                let item = items[next]
                group.addTask { await transform(item) }
                next += 1
            }
            while let finished = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                if let value = finished { await handle(value) }
                if next < items.count {
                    let item = items[next]
                    group.addTask { await transform(item) }
                    next += 1
                }
            }
        }
    }
}
