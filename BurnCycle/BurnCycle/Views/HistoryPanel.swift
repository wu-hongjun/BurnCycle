import SwiftUI
import Charts

/// History panel extracted from MainView: a Swift Charts plot of battery health %
/// and full-charge capacity over cycle count (with a hover readout and rule), plus
/// a scrolling table of recorded entries and a "Clear All" action. The chart-scale
/// helpers below keep the two series aligned on a single Y axis.
struct HistoryPanel: View {
    @ObservedObject var history: HistoryRecorder

    @State private var showClearConfirm = false
    /// History-chart entry currently under the cursor (nil when not hovering).
    @State private var hoverEntry: HistoryEntry?

    /// Entries plotted by the chart: only the currently installed battery. After
    /// a replacement the cycle count resets, and plotting the whole array would
    /// draw the old pack's last point straight back to cycle 1 and let the
    /// outlier dominate the auto-zoomed axes. The table below still lists all.
    private var chartEntries: [HistoryEntry] { history.currentBatteryEntries }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Chart of health % (left axis) and full-charge capacity in mAh
            // (right axis) over cycle count. Apple's reported health is an
            // integer that holds the same value for 100+ cycles, so on its
            // own it's a flat line; capacity in mAh has far finer resolution
            // and reveals the actual degradation trend. Capacity is plotted
            // in the health axis' coordinate space (see capacityToHealthScale)
            // so a single chart keeps both series perfectly aligned, with the
            // trailing axis de-normalizing the ticks back to mAh.
            if chartEntries.count >= 2 {
                // Hover readout — reflects the entry under the cursor. Fixed
                // height so the layout doesn't jump as it appears/clears.
                HStack(spacing: 8) {
                    if let e = hoverEntry {
                        Text("Cycle \(e.cycleCount)").fontWeight(.semibold)
                        Text("\(e.fullChargeCapacityMAh) mAh").foregroundStyle(.blue)
                        Text("\(e.healthPercent)%").foregroundStyle(.green)
                        Spacer()
                        Text(e.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Hover the chart for exact values")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .font(.caption2)
                .frame(height: 14)

                Chart {
                    ForEach(chartEntries) { entry in
                        LineMark(
                            x: .value("Cycle", entry.cycleCount),
                            y: .value("Health %", Double(entry.healthPercent)),
                            series: .value("Series", "Health %")
                        )
                        .foregroundStyle(by: .value("Series", "Health %"))
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Cycle", entry.cycleCount),
                            y: .value("Capacity", capacityToHealthScale(entry.fullChargeCapacityMAh)),
                            series: .value("Series", "Capacity (mAh)")
                        )
                        .foregroundStyle(by: .value("Series", "Capacity (mAh)"))
                        .interpolationMethod(.monotone)
                    }

                    // Hover feedback: a vertical rule marks the entry under
                    // the cursor; the exact values are shown in the readout
                    // line above the chart (the 120pt frame is too tight for
                    // an in-chart annotation without clipping).
                    if let e = hoverEntry {
                        RuleMark(x: .value("Cycle", e.cycleCount))
                            .foregroundStyle(.gray.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .chartForegroundStyleScale(["Health %": Color.green, "Capacity (mAh)": Color.blue])
                .chartYScale(domain: Double(chartHealthDomain.lowerBound)...Double(chartHealthDomain.upperBound))
                .chartXScale(domain: chartCycleDomain)
                .chartYAxis {
                    // Leading axis: real health % ticks (green).
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        if let v = value.as(Double.self) {
                            AxisValueLabel { Text("\(Int(v.rounded()))").foregroundStyle(.green) }
                        }
                    }
                    // Trailing axis: same tick positions, de-normalized to mAh (blue).
                    AxisMarks(position: .trailing) { value in
                        if let v = value.as(Double.self) {
                            AxisValueLabel { Text("\(healthScaleToCapacity(v))").foregroundStyle(.blue) }
                        }
                    }
                }
                .chartXAxisLabel("Cycle")
                .chartLegend(position: .bottom, spacing: 4)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else { hoverEntry = nil; return }
                                    let xPos = location.x - geo[plotFrame].origin.x
                                    guard let cycle = proxy.value(atX: xPos, as: Int.self) else { hoverEntry = nil; return }
                                    hoverEntry = nearestEntry(toCycle: cycle)
                                case .ended:
                                    hoverEntry = nil
                                }
                            }
                    }
                }
                .frame(height: 120)
                .padding(.bottom, 4)

                Divider()
            }

            HStack {
                Text("Cycle").fontWeight(.semibold).frame(width: 45, alignment: .leading)
                Text("Date").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                Text("Capacity (mAh)").fontWeight(.semibold).frame(width: 90, alignment: .trailing)
                Text("Health").fontWeight(.semibold).frame(width: 50, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundColor(.secondary)

            Divider()

            if history.entries.isEmpty {
                Text("No history yet. An entry is recorded on first observation and on every cycle count change.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Show up to 5 rows; scroll if more.
                // Each row ≈ 18pt (caption2 + 4 spacing).
                let rowHeight: CGFloat = 18
                let visibleRows = min(history.entries.count, 5)
                let scrollHeight = CGFloat(visibleRows) * rowHeight
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(history.entries.reversed()) { entry in
                            HStack {
                                Text("\(entry.cycleCount)")
                                    .frame(width: 45, alignment: .leading)
                                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(entry.fullChargeCapacityMAh)")
                                    .frame(width: 90, alignment: .trailing)
                                Text("\(entry.healthPercent)%")
                                    .frame(width: 50, alignment: .trailing)
                                    .foregroundColor(entry.healthPercent > 80 ? .green : entry.healthPercent > 50 ? .yellow : .red)
                            }
                            .font(.caption2)
                        }
                    }
                }
                .frame(height: scrollHeight)

                HStack {
                    Text("\(history.entries.count) entries")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button("Clear All") {
                        showClearConfirm = true
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .tint(.red)
                    .confirmationDialog("Delete all history?",
                                        isPresented: $showClearConfirm,
                                        titleVisibility: .visible) {
                        Button("Delete All Entries", role: .destructive) {
                            history.clearAll()
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This permanently removes all recorded battery health history. This cannot be undone.")
                    }
                }
            }

            if let saveErr = history.lastError {
                Label(saveErr, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundColor(.orange)
            }
        }
        .padding(.top, 4)
    }

    /// Auto-zoom Y axis around recorded health values for clearer trend visibility
    private var chartHealthDomain: ClosedRange<Int> {
        let values: [Int] = chartEntries.map { $0.healthPercent }
        guard let lo = values.min(), let hi = values.max() else { return 0...100 }
        let pad: Int = max(2, (hi - lo) / 4)
        return max(0, lo - pad)...min(100, hi + pad)
    }

    /// X axis range — starts at the smallest recorded cycle, not 0
    private var chartCycleDomain: ClosedRange<Int> {
        let values: [Int] = chartEntries.map { $0.cycleCount }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        // If only one unique cycle value, pad so the line is visible
        if lo == hi { return (lo - 1)...(hi + 1) }
        let pad: Int = max(1, (hi - lo) / 10)
        return max(0, lo - pad)...(hi + pad)
    }

    /// Auto-zoomed mAh range for the capacity (right) axis. Padded so the trend
    /// fills the plot rather than hugging an edge.
    private var chartCapacityDomain: ClosedRange<Int> {
        let values: [Int] = chartEntries.map { $0.fullChargeCapacityMAh }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if lo == hi { return (lo - 10)...(hi + 10) }
        let pad: Int = max(5, (hi - lo) / 4)
        return (lo - pad)...(hi + pad)
    }

    /// Map a capacity (mAh) into the health axis' coordinate space so both
    /// series share one Y scale and stay perfectly aligned. Linear remap from
    /// the capacity domain onto the health domain.
    private func capacityToHealthScale(_ capacity: Int) -> Double {
        let h = chartHealthDomain, c = chartCapacityDomain
        let cLo = Double(c.lowerBound), cHi = Double(c.upperBound)
        let hLo = Double(h.lowerBound), hHi = Double(h.upperBound)
        guard cHi > cLo else { return hLo }
        return hLo + (Double(capacity) - cLo) / (cHi - cLo) * (hHi - hLo)
    }

    /// Inverse of `capacityToHealthScale` — turns a health-axis tick position
    /// back into the mAh value it represents, for the trailing axis labels.
    private func healthScaleToCapacity(_ y: Double) -> Int {
        let h = chartHealthDomain, c = chartCapacityDomain
        let cLo = Double(c.lowerBound), cHi = Double(c.upperBound)
        let hLo = Double(h.lowerBound), hHi = Double(h.upperBound)
        guard hHi > hLo else { return c.lowerBound }
        return Int((cLo + (y - hLo) / (hHi - hLo) * (cHi - cLo)).rounded())
    }

    /// Entry whose cycle count is closest to `cycle` (the hovered x position).
    private func nearestEntry(toCycle cycle: Int) -> HistoryEntry? {
        chartEntries.min(by: { abs($0.cycleCount - cycle) < abs($1.cycleCount - cycle) })
    }
}
