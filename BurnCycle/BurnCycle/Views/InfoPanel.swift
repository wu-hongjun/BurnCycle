import SwiftUI

/// Info panel extracted from MainView: detailed battery readings (capacity,
/// design capacity, real/Apple health, cycles, temperature, voltage, serial,
/// and adapter/output power). `infoRow` formats each label/value pair.
struct InfoPanel: View {
    @ObservedObject var battery: BatteryMonitor

    var body: some View {
        VStack(spacing: 6) {
            infoRow("Battery Charge", "\(battery.currentCapacityMAh) mAh (\(battery.percentage)%)")
            infoRow("Full Charge Capacity", "\(battery.fullChargeCapacityMAh) mAh")
            infoRow("Design Capacity", "\(battery.designCapacityMAh) mAh")
            if battery.designCapacityMAh > 0 {
                infoRow("Battery Health (Real)", String(format: "%.1f%%",
                    Double(battery.fullChargeCapacityMAh) / Double(battery.designCapacityMAh) * 100))
            }
            infoRow("Battery Health (Apple)", "\(battery.healthPercent)%")
            infoRow("Charge Cycles", "\(battery.cycleCount)")
            infoRow("Temperature", String(format: "%.1f °C", battery.temperature))
            infoRow("Voltage", String(format: "%.3f V", battery.voltage))
            infoRow("Serial", battery.serial.isEmpty ? "—" : battery.serial)
            if battery.isPluggedIn {
                infoRow("Power Adapter", battery.adapterName.isEmpty ? "—" : battery.adapterName)
                infoRow("Battery Input", String(format: "%.1f W", battery.chargingWatts))
            } else {
                infoRow("Battery Output", String(format: "%.1f W", battery.chargingWatts))
            }
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}
