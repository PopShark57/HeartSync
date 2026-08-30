import Foundation

/// Derived metrics HeartSync computes when no device measures them directly.
///
/// Everything in this file produces `Provenance.estimated` values. They are modelled
/// guesses, and the UI labels them as such everywhere they appear.
enum Estimators {

    // MARK: - VO2 Max

    /// Non-exercise VO\u{2082} max estimate from the ratio of maximum to resting heart rate.
    ///
    /// Uth, S\u{00F8}rensen, Overgaard & Pedersen (2004) found `VO2max \u{2248} 15.3 \u{00D7} (HRmax / HRrest)`
    /// in trained and untrained adults. It is a genuinely useful population-level estimate
    /// with a standard error around 10\u{2013}15%, which is far wider than the \u{00B1}3 mL/kg\u{00B7}min
    /// tolerance the comparison engine uses \u{2014} so an estimate will often "disagree" with an
    /// Apple Watch measurement. That is a property of the estimate, not a device fault, and
    /// the comparison engine excludes estimated values from discrepancy flagging.
    ///
    /// - Parameters:
    ///   - restingHeartRate: measured resting HR in bpm.
    ///   - maxHeartRate: measured max HR if known, otherwise the age-predicted value.
    static func vo2Max(restingHeartRate: Double, maxHeartRate: Double) -> Double? {
        guard restingHeartRate >= 30, restingHeartRate <= 120,
              maxHeartRate > restingHeartRate, maxHeartRate <= 220
        else { return nil }
        let value = 15.3 * (maxHeartRate / restingHeartRate)
        guard MetricKind.vo2Max.plausibleRange.contains(value) else { return nil }
        return value
    }

    // MARK: - Blood pressure trend index

    /// A blood-pressure *trend* estimate anchored to a real cuff reading.
    ///
    /// This is deliberately not presented as a blood-pressure measurement. Optical sensors
    /// in rings and watches cannot measure blood pressure: pulse-transit-time methods need
    /// two synchronised sensors and per-user calibration, and single-site PPG morphology
    /// methods have not been shown to track absolute pressure in free-living consumers.
    ///
    /// What this does instead is express how far the user's current cardiovascular state
    /// has drifted from the state they were in when they took a cuff reading, using the
    /// two signals that do covary with pressure at rest: heart rate and vagal tone.
    /// The output is clamped to a narrow band around the calibration and always carries a
    /// wide interval, because the honest uncertainty is wide.
    struct BloodPressureEstimate: Equatable, Sendable {
        var systolic: Double
        var diastolic: Double
        /// Half-width of the plausible interval, in mmHg. Widens as the calibration ages.
        var systolicMargin: Double
        var diastolicMargin: Double
        var basedOn: Date

        var systolicRange: ClosedRange<Double> {
            (systolic - systolicMargin)...(systolic + systolicMargin)
        }
        var diastolicRange: ClosedRange<Double> {
            (diastolic - diastolicMargin)...(diastolic + diastolicMargin)
        }

        static let disclaimer = """
            This is not a blood pressure measurement. It is an estimate of how far your \
            cardiovascular state has drifted from your last cuff reading, based on heart \
            rate and HRV. Do not use it to make any medical decision, to diagnose \
            hypertension, or to adjust medication. Use a validated cuff.
            """
    }

    /// mmHg of systolic change modelled per bpm of heart-rate change from the calibration
    /// point. Resting HR\u{2013}BP coupling in the literature sits around 0.3\u{2013}0.5 mmHg/bpm;
    /// the low end is used because overstating the slope produces confident nonsense.
    static let systolicPerBPM = 0.35
    static let diastolicPerBPM = 0.20

    /// Maximum mmHg the HRV term may contribute in either direction. Reduced vagal tone
    /// associates with higher pressure, but the effect size in an individual over hours is
    /// small, so it is capped tightly.
    static let maxHRVContributionSystolic = 5.0
    static let maxHRVContributionDiastolic = 3.0

    /// The model is only meaningful near the operating point it was calibrated at.
    /// Beyond this the estimate is suppressed entirely rather than extrapolated.
    static let maxHeartRateDeviation = 25.0

    /// Total drift from calibration is clamped here, because a linear model run far from
    /// its anchor stops being informative long before it stops producing numbers.
    static let maxSystolicDrift = 18.0
    static let maxDiastolicDrift = 12.0

    /// - Returns: `nil` when there is no usable calibration, when it has expired, or when
    ///   the current heart rate is too far from the calibration point for the model to
    ///   have anything to say.
    static func bloodPressure(
        calibration: UserProfile.BPCalibration,
        currentHeartRate: Double,
        currentRMSSD: Double?,
        now: Date = .now
    ) -> BloodPressureEstimate? {
        guard !calibration.isExpired else { return nil }
        guard MetricKind.heartRate.plausibleRange.contains(currentHeartRate) else { return nil }

        let hrDelta = currentHeartRate - calibration.referenceRestingHR
        guard abs(hrDelta) <= maxHeartRateDeviation else { return nil }

        var systolicDrift = hrDelta * systolicPerBPM
        var diastolicDrift = hrDelta * diastolicPerBPM

        // Vagal-tone term: RMSSD below the calibration reference nudges the estimate up.
        if let currentRMSSD, let reference = calibration.referenceRMSSD,
           reference > 0, currentRMSSD > 0 {
            let relativeDrop = (reference - currentRMSSD) / reference   // positive = less HRV
            let clamped = max(-1, min(1, relativeDrop))
            systolicDrift  += clamped * maxHRVContributionSystolic
            diastolicDrift += clamped * maxHRVContributionDiastolic
        }

        systolicDrift  = max(-maxSystolicDrift,  min(maxSystolicDrift,  systolicDrift))
        diastolicDrift = max(-maxDiastolicDrift, min(maxDiastolicDrift, diastolicDrift))

        let systolic = calibration.systolic + systolicDrift
        let diastolic = calibration.diastolic + diastolicDrift

        guard MetricKind.bloodPressureSystolic.plausibleRange.contains(systolic),
              MetricKind.bloodPressureDiastolic.plausibleRange.contains(diastolic),
              systolic > diastolic
        else { return nil }

        // Interval starts wide and widens further as the anchor ages, reaching roughly
        // double by the time the calibration expires.
        let ageFraction = now.timeIntervalSince(calibration.takenAt)
            / UserProfile.BPCalibration.validity
        let widening = 1 + max(0, min(1, ageFraction))

        return BloodPressureEstimate(
            systolic: systolic,
            diastolic: diastolic,
            systolicMargin: 8 * widening,
            diastolicMargin: 5 * widening,
            basedOn: calibration.takenAt
        )
    }
}
