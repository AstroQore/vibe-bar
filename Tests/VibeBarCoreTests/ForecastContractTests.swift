import XCTest
@testable import VibeBarCore

/// The forecast is shared with Vibe Bar Desktop through
/// `docs/contracts/forecast-v1.json`: both clients evaluate each case at 25%,
/// 50%, 75% and 95% of its window and must agree on every field. Verdicts and
/// confidences exactly; numbers to 1e-6, far tighter than any difference a
/// reader could see, because a gap that small means the two implementations
/// have started diverging rather than that one of them rounded.
///
/// The vectors used to live only in the other repository, which had the
/// direction backwards: this is the reference implementation, so a change here
/// went unchecked while the port's test suite turned red. Now a change to
/// `QuotaPaceForecast` fails here first.
final class ForecastContractTests: XCTestCase {
    /// `Tests/VibeBarCoreTests/<this file>` → three levels up.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private struct Contract: Decodable {
        struct Observation: Decodable {
            let sampledAt: Double
            let usedPercent: Double
        }
        struct Cycle: Decodable {
            let windowStart: Double
            let windowEnd: Double
            /// The last observation that belonged to this cycle, which decides
            /// which readings the historical projection may compare against.
            /// Published because it cannot be derived from the boundaries.
            let lastSeenAt: Double?
            let peakUsedPercent: Double
        }
        struct Input: Decodable {
            let rawWindowSeconds: Int
            let resetAt: Double
            let observations: [Observation]
            let completedCycles: [Cycle]?
        }
        struct Case: Decodable {
            let name: String
            let description: String
            let input: Input
            let expected: [JSONValue]
        }
        /// A bare version number here, where the other contracts spell out a
        /// name. Not worth churning the published file over, but worth not
        /// assuming.
        let schema: Int
        let numericTolerance: Double
        let evaluationFractions: [Double]
        let cases: [Case]
    }

    /// Just enough to read heterogeneous expectation rows without a struct per
    /// field, and to tell an absent `runOutAt` from a present one.
    private enum JSONValue: Decodable {
        case object([String: JSONValue])
        case string(String)
        case number(Double)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else {
                self = .other
            }
        }

        subscript(key: String) -> JSONValue? {
            if case .object(let fields) = self { return fields[key] }
            return nil
        }
        var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }
        var numberValue: Double? {
            if case .number(let value) = self { return value }
            return nil
        }
    }

    func testTheForecastMatchesTheSharedVectors() throws {
        let url = repositoryRoot.appendingPathComponent("docs/contracts/forecast-v1.json")
        let contract = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
        XCTAssertEqual(contract.schema, 1)

        var checked = 0
        for testCase in contract.cases {
            let window = TimeInterval(testCase.input.rawWindowSeconds)
            let resetAt = Date(timeIntervalSince1970: testCase.input.resetAt)
            let observations = testCase.input.observations.map {
                FillTimelinePoint(
                    accountId: "account",
                    tool: .codex,
                    bucketId: "weekly",
                    slotStart: UsageFillTimelineStore.hourSlotStart(
                        for: Date(timeIntervalSince1970: $0.sampledAt)
                    ),
                    usedPercent: $0.usedPercent,
                    sampledAt: Date(timeIntervalSince1970: $0.sampledAt),
                    resetAt: resetAt,
                    rawWindowSeconds: testCase.input.rawWindowSeconds
                )
            }
            let cycles = (testCase.input.completedCycles ?? []).map { cycle in
                SubscriptionWindowSample(
                    accountId: "account",
                    tool: .codex,
                    bucketId: "weekly",
                    windowEnd: Date(timeIntervalSince1970: cycle.windowEnd),
                    windowStart: Date(timeIntervalSince1970: cycle.windowStart),
                    rawWindowSeconds: testCase.input.rawWindowSeconds,
                    peakUsedPercent: cycle.peakUsedPercent,
                    lastUsedPercent: cycle.peakUsedPercent,
                    observationCount: 12,
                    firstSeenAt: Date(timeIntervalSince1970: cycle.windowStart),
                    lastSeenAt: Date(
                        timeIntervalSince1970: cycle.lastSeenAt ?? (cycle.windowEnd - 600)
                    ),
                    completedAt: Date(timeIntervalSince1970: cycle.windowEnd),
                    completionReason: .scheduledReset
                )
            }

            var expectations = testCase.expected.makeIterator()
            for fraction in contract.evaluationFractions {
                let now = resetAt.addingTimeInterval(-window * (1 - fraction))
                let visible = observations.filter { $0.sampledAt <= now }
                guard let last = visible.last else { continue }
                // Not `continue`: a case that stops producing a forecast would
                // vanish from the run, and the remaining cases still cleared
                // the total-count check at the end.
                let forecast = try XCTUnwrap(
                    QuotaPaceForecast.compute(
                        bucket: QuotaBucket(
                            id: "weekly",
                            title: "Weekly",
                            shortLabel: "Weekly",
                            usedPercent: last.usedPercent,
                            resetAt: resetAt,
                            rawWindowSeconds: testCase.input.rawWindowSeconds
                        ),
                        observations: visible,
                        cycles: cycles,
                        now: now
                    ),
                    "\(testCase.name) @ \(Int(fraction * 100))%: no forecast at all"
                )
                let want = try XCTUnwrap(
                    expectations.next(),
                    "\(testCase.name): more results than expectations"
                )
                let context = "\(testCase.name) @ \(Int(fraction * 100))%"
                checked += 1

                XCTAssertEqual(forecast.verdict.rawValue, want["verdict"]?.stringValue,
                               "\(context): verdict")
                XCTAssertEqual(forecast.confidence.rawValue, want["confidence"]?.stringValue,
                               "\(context): confidence")
                for (label, got, key) in [
                    ("confidenceScore", forecast.confidenceScore, "confidenceScore"),
                    ("planned", forecast.plannedUsedPercent, "planned"),
                    ("projected", forecast.projectedUsedPercent, "projected"),
                    ("lower", forecast.projectedUsedLowerPercent, "lower"),
                    ("upper", forecast.projectedUsedUpperPercent, "upper"),
                    ("target", forecast.targetRemainingPercent, "target"),
                ] {
                    let expected = try XCTUnwrap(want[key]?.numberValue, "\(context): no \(label)")
                    XCTAssertEqual(got, expected, accuracy: contract.numericTolerance,
                                   "\(context): \(label)")
                }
                // Presence first: "never runs out" and "ran out at the epoch"
                // are opposite claims, not numbers a tolerance can bridge.
                switch (forecast.runOutAt, want["runOutAt"]?.numberValue) {
                case (nil, nil):
                    break
                case (let got?, let expected?):
                    XCTAssertEqual(got.timeIntervalSince1970, expected,
                                   accuracy: contract.numericTolerance, "\(context): runOutAt")
                case (let got, let expected):
                    XCTFail(
                        "\(context): runOutAt \(String(describing: got)) vs "
                            + "\(String(describing: expected)) — one client predicts running "
                            + "out and the other does not"
                    )
                }
                XCTAssertEqual(
                    Double(forecast.currentObservationCount),
                    want["observationCount"]?.numberValue, "\(context): observationCount"
                )
                XCTAssertEqual(
                    Double(forecast.diagnostics.recentSampleCount),
                    want["recentSampleCount"]?.numberValue, "\(context): recentSampleCount"
                )
                // The historical diagnostics are published, so they are part of
                // the agreement. Without these the two clients could blend the
                // same verdict out of different histories.
                XCTAssertEqual(
                    Double(forecast.completedCycleCount),
                    want["completedCycleCount"]?.numberValue ?? 0,
                    "\(context): completedCycleCount"
                )
                switch (
                    forecast.diagnostics.historicalProjectionUsedPercent,
                    want["historicalProjection"]?.numberValue
                ) {
                case (nil, nil):
                    break
                case (let got?, let expected?):
                    XCTAssertEqual(got, expected, accuracy: contract.numericTolerance,
                                   "\(context): historicalProjection")
                case (let got, let expected):
                    XCTFail(
                        "\(context): historicalProjection \(String(describing: got)) vs "
                            + "\(String(describing: expected)) — one client compared against "
                            + "past cycles and the other did not"
                    )
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 20, "the vectors stopped being evaluated")
    }
}
