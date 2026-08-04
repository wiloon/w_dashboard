import SwiftUI
import WDashboardCore

struct WeatherView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weather").font(.headline)
            if !appState.weatherConfigured {
                Text("Not configured").foregroundStyle(.secondary).font(.subheadline)
            } else if let report = appState.weatherReport {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.locationLabel).font(.subheadline.bold())
                        HStack(spacing: 8) {
                            Image(systemName: wmoSymbolName(report.current.weatherCode))
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 32))
                            Text(temperatureString(report.current.temperature, report.temperatureUnit))
                                .font(.system(size: 32, weight: .semibold))
                        }
                        Text(report.current.description).foregroundStyle(.secondary)
                        if let error = appState.weatherError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(report.daily, id: \.date) { day in
                                VStack(spacing: 4) {
                                    Text(day.date).font(.caption2)
                                    Image(systemName: wmoSymbolName(day.weatherCode))
                                        .symbolRenderingMode(.multicolor)
                                        .font(.system(size: 20))
                                    Text(day.description)
                                        .font(.caption)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                    Text(temperatureString(day.tempMax, report.temperatureUnit)).font(.caption.bold())
                                    Text(temperatureString(day.tempMin, report.temperatureUnit))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let precip = day.precipitationProbabilityMax {
                                        Text("precip \(precip)%").font(.caption2).foregroundStyle(.blue)
                                    }
                                }
                                .frame(width: 92)
                            }
                        }
                    }
                }
            } else if let error = appState.weatherError {
                Text(error).foregroundStyle(.red).font(.subheadline)
            } else {
                Text("Loading…").foregroundStyle(.secondary).font(.subheadline)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }
}

private func temperatureString(_ value: Double, _ unit: String) -> String {
    let symbol = unit == "fahrenheit" ? "°F" : "°C"
    return String(format: "%.1f%@", value, symbol)
}
