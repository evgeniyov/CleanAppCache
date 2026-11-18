import XCTest
@testable import CleanAppCacheLib

/// The status-bar pairing rule: which pinned metrics become columns and
/// which temperature rides on top of each.
///
/// A controller with persistence and sampling disabled exercises the real
/// layout rules without touching preferences or starting background work.
@MainActor
final class MenuBarLayoutTests: XCTestCase {
    private let controller = MenuBarController(defaults: nil, startSampling: false)

    /// Every case starts with its own pinned metrics and leaves the fixture reusable.
    private func restoringSelection(_ body: () -> Void) {
        let saved = controller.selectedMetrics
        defer { controller.selectedMetrics = saved }
        body()
    }

    private func cells(_ pinned: [MenuBarMetric], _ style: MenuBarStyle) -> [MenuBarController.WidgetCell] {
        controller.selectedMetrics = pinned
        // The raw key as caption, so a paired temperature ("46°" / "—") can
        // never collide with it.
        return controller.widgetCells(style: style, localized: { $0 })
    }

    private func metrics(_ pinned: [MenuBarMetric], _ style: MenuBarStyle) -> [MenuBarMetric] {
        cells(pinned, style).compactMap { MenuBarMetric(rawValue: $0.id) }
    }

    /// True per column when a temperature sits on the upper tier instead of the
    /// column's own caption.
    private func paired(_ pinned: [MenuBarMetric], _ style: MenuBarStyle) -> [Bool] {
        cells(pinned, style).map { $0.top != $0.caption }
    }

    func testStackFoldsTemperatureIntoItsLoadColumn() {
        restoringSelection {
            XCTAssertEqual(metrics([.cpuLoad, .cpuTemp], .stack), [.cpuLoad])
            XCTAssertEqual(paired([.cpuLoad, .cpuTemp], .stack), [true])
            // Pin order does not matter; the column sits where the load is.
            XCTAssertEqual(metrics([.cpuTemp, .memLoad, .cpuLoad], .stack), [.memLoad, .cpuLoad])
            XCTAssertEqual(paired([.cpuTemp, .memLoad, .cpuLoad], .stack), [false, true])
            XCTAssertEqual(metrics([.gpuLoad, .gpuTemp, .memLoad], .stack), [.gpuLoad, .memLoad])
            XCTAssertEqual(paired([.gpuLoad, .gpuTemp, .memLoad], .stack), [true, false])
        }
    }

    func testTemperatureWithoutItsLoadStandsAlone() {
        restoringSelection {
            XCTAssertEqual(metrics([.cpuTemp], .stack), [.cpuTemp])
            XCTAssertEqual(metrics([.cpuTemp, .gpuLoad], .stack), [.cpuTemp, .gpuLoad],
                           "cpuTemp must not fold into the GPU column")
            XCTAssertEqual(paired([.cpuTemp, .gpuLoad], .stack), [false, false])
        }
    }

    /// Regression (fc22dab): every non-stacked layout keeps all pinned metrics.
    func testOnlyStackPairs() {
        restoringSelection {
            let pinned: [MenuBarMetric] = [.cpuLoad, .cpuTemp, .gpuLoad, .gpuTemp, .memLoad]
            for style in MenuBarStyle.allCases where style != .stack {
                XCTAssertEqual(metrics(pinned, style), pinned, "\(style) dropped a metric")
                XCTAssertFalse(paired(pinned, style).contains(true), "\(style) paired a temperature")
            }
            XCTAssertEqual(metrics(pinned, .stack), [.cpuLoad, .gpuLoad, .memLoad])
        }
    }

    /// Readings are floored to a tenth so unchanged ticks compare equal. That
    /// is only allowed because no printed figure moves: the bar truncates, the
    /// popover rounds, and the temperature words compare against whole degrees.
    func testDisplayedPrecisionKeepsEveryPrintedFigure() {
        var samples = (0...150_000).map { Double($0) / 1000 }
        samples += (0..<20_000).map { _ in Double.random(in: 0...150) }
        samples += [42.5, 42.5.nextDown, 43.0.nextDown, 84.95, 85.0.nextDown, 85]
        let changed = samples.filter { raw in
            let shown = MenuBarReadings.displayed(raw)
            return Int(shown) != Int(raw)
                || Int(shown.rounded()) != Int(raw.rounded())
                || (shown >= 85) != (raw >= 85)
        }
        XCTAssertEqual(changed, [], "readings whose printed figure moved")
    }

    /// The status item redraws when its state changes, so the state carries the
    /// sparkline and the per-core loads only for the layouts that draw them,
    /// and the dotted separator is part of what it compares.
    func testLabelStateCarriesOnlyWhatItsLayoutDraws() {
        restoringSelection {
            controller.selectedMetrics = [.cpuLoad, .memLoad]
            for style in MenuBarStyle.allCases {
                let state = controller.labelState(style: style)
                if style != .graph { XCTAssertTrue(state.history.isEmpty, "\(style) carries history") }
                if style != .cores { XCTAssertTrue(state.perCore.isEmpty, "\(style) carries cores") }
                XCTAssertEqual(state.cells.count, style.showsSingleMetric ? 1 : 2, "\(style)")
                XCTAssertEqual(state, controller.labelState(style: style), "\(style) is not stable")
            }
            let dotted = controller.labelState(style: .dotted).cells.map(\.value)
            XCTAssertFalse(dotted[0].hasPrefix("· "))
            XCTAssertTrue(dotted[1].hasPrefix("· "))
        }
    }

    /// Every cell is keyed by its metric; a duplicate id would make SwiftUI's
    /// ForEach draw undefined results.
    func testCellIDsAreTheMetricsThemselves() {
        restoringSelection {
            let ids = cells([.memLoad, .cpuLoad, .cpuTemp], .inline).map(\.id)
            XCTAssertEqual(ids, ["memLoad", "cpuLoad", "cpuTemp"])
        }
    }
}
