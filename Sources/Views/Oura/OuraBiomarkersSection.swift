import SwiftUI

/// Latest per-biomarker values as Oura processed them.
///
/// Every card is a cloud-derived figure, not a HeartSync measurement, and the detail line on
/// each card says where the number comes from. Two distinctions in here are load-bearing and
/// must survive any edit: `average_hrv` is RMSSD (never SDNN), and temperature is a deviation
/// from the user's own Oura baseline, never an absolute body temperature.
struct OuraBiomarkersSection: View {
    var heartRate: OuraClient.HeartRatePoint?
    var sleep: OuraClient.SleepDocument?
    var readiness: OuraClient.DailyReadiness?
    var oxygen: OuraClient.DailySpO2?
    var cardiovascularAge: OuraClient.DailyCardiovascularAge?
    var vo2Max: OuraClient.VO2MaxDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OuraSectionHeading(
                title: "Biomarkers",
                subtitle: "Latest values processed by Oura",
                systemImage: "waveform.path.ecg"
            )

            LazyVGrid(columns: OuraCardLayout.metricColumns, spacing: 12) {
                ForEach(biomarkers) { item in
                    OuraBiomarkerCard(item: item)
                }
            }
        }
    }

    private var biomarkers: [OuraBiomarkerItem] {
        [
            OuraBiomarkerItem(
                id: "heart-rate",
                title: "Heart rate",
                value: heartRate.map { String($0.bpm) } ?? "—",
                unit: "bpm",
                detail: OuraFormat.pretty(heartRate?.source) ?? "Latest sample",
                icon: "heart.fill",
                tint: .pink
            ),
            OuraBiomarkerItem(
                id: "resting-heart-rate",
                title: "Resting HR",
                value: OuraFormat.number(sleep?.lowest_heart_rate, digits: 0),
                unit: "bpm",
                detail: "Nightly low",
                icon: "heart.circle.fill",
                tint: .red
            ),
            OuraBiomarkerItem(
                id: "hrv",
                title: "HRV (RMSSD)",
                value: OuraFormat.number(sleep?.average_hrv, digits: 0),
                unit: "ms",
                detail: "Nightly average",
                icon: "waveform.path.ecg",
                tint: .purple
            ),
            OuraBiomarkerItem(
                id: "respiration",
                title: "Respiration",
                value: OuraFormat.number(sleep?.average_breath, digits: 1),
                unit: "br/min",
                detail: "During sleep",
                icon: "wind",
                tint: .teal
            ),
            OuraBiomarkerItem(
                id: "oxygen",
                title: "Blood oxygen",
                value: OuraFormat.number(oxygen?.spo2_percentage?.average, digits: 1),
                unit: "%",
                detail: "Sleep average",
                icon: "lungs.fill",
                tint: .blue
            ),
            OuraBiomarkerItem(
                id: "bdi",
                title: "Breathing disturbances",
                value: oxygen?.breathing_disturbance_index.map(String.init) ?? "—",
                unit: "index",
                detail: "Detected SpO₂ drops",
                icon: "waveform.badge.magnifyingglass",
                tint: .cyan
            ),
            OuraBiomarkerItem(
                id: "temperature",
                title: "Temperature deviation",
                value: OuraFormat.signed(readiness?.temperature_deviation, digits: 1),
                unit: "°C",
                detail: "From your Oura baseline",
                icon: "thermometer.medium",
                tint: .orange
            ),
            OuraBiomarkerItem(
                id: "vo2-max",
                title: "VO₂ max",
                value: OuraFormat.number(vo2Max?.vo2_max, digits: 1),
                unit: "mL/kg·min",
                detail: OuraFormat.dayLabel(vo2Max?.day),
                icon: "figure.run",
                tint: .green
            ),
            OuraBiomarkerItem(
                id: "vascular-age",
                title: "Vascular age",
                value: cardiovascularAge?.vascular_age.map(String.init) ?? "—",
                unit: "years",
                detail: OuraFormat.dayLabel(cardiovascularAge?.day),
                icon: "calendar.badge.clock",
                tint: .mint
            ),
            OuraBiomarkerItem(
                id: "pulse-wave",
                title: "Pulse wave velocity",
                value: OuraFormat.number(cardiovascularAge?.pulse_wave_velocity, digits: 1),
                unit: "m/s",
                detail: "Oura cardiovascular estimate",
                icon: "waveform.path",
                tint: .indigo
            ),
        ]
    }
}
