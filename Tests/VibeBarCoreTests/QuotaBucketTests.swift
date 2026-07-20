import XCTest
@testable import VibeBarCore

final class QuotaBucketTests: XCTestCase {
    /// `min/max` over Doubles passes NaN through in one ordering and
    /// silently turns it into the bound in the other. Without an
    /// explicit isFinite gate, a non-finite percent from a buggy
    /// parser would surface as 100% used. The init clamps to 0 instead.
    func testNonFiniteUsedPercentClampsToZero() {
        let nanBucket = QuotaBucket(id: "x", title: "x", shortLabel: "x", usedPercent: .nan)
        XCTAssertEqual(nanBucket.usedPercent, 0, accuracy: 0.001)

        let positiveInfBucket = QuotaBucket(id: "y", title: "y", shortLabel: "y", usedPercent: .infinity)
        XCTAssertEqual(positiveInfBucket.usedPercent, 0, accuracy: 0.001)

        let negativeInfBucket = QuotaBucket(id: "z", title: "z", shortLabel: "z", usedPercent: -.infinity)
        XCTAssertEqual(negativeInfBucket.usedPercent, 0, accuracy: 0.001)
    }

    func testFiniteUsedPercentClampsToZeroOneHundred() {
        XCTAssertEqual(QuotaBucket(id: "a", title: "a", shortLabel: "a", usedPercent: -5).usedPercent, 0, accuracy: 0.001)
        XCTAssertEqual(QuotaBucket(id: "b", title: "b", shortLabel: "b", usedPercent: 150).usedPercent, 100, accuracy: 0.001)
        XCTAssertEqual(QuotaBucket(id: "c", title: "c", shortLabel: "c", usedPercent: 42.5).usedPercent, 42.5, accuracy: 0.001)
    }

    func testQuotaWindowLabelsAlwaysUseFullWords() throws {
        XCTAssertEqual(QuotaBucket(id: "a", title: "a", shortLabel: "5h", usedPercent: 0).shortLabel, "5 Hours")
        XCTAssertEqual(QuotaBucket(id: "b", title: "b", shortLabel: "Wk", usedPercent: 0).shortLabel, "Weekly")
        XCTAssertEqual(QuotaBucket(id: "c", title: "c", shortLabel: "Spark 5h", usedPercent: 0).shortLabel, "Spark 5 Hours")
        XCTAssertEqual(QuotaBucket(id: "d", title: "d", shortLabel: "Fable wk", usedPercent: 0).shortLabel, "Fable Weekly")
        XCTAssertEqual(QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "All models", usedPercent: 0).shortLabel, "Weekly")

        let cachedJSON = #"{"id":"cached","title":"Weekly","shortLabel":"wk","usedPercent":20}"#.data(using: .utf8)!
        let restored = try JSONDecoder().decode(QuotaBucket.self, from: cachedJSON)
        XCTAssertEqual(restored.shortLabel, "Weekly")
    }
}
