import Foundation

/// Apple Watch measurements that Health records under the paired iPhone.
///
/// The redesigned Blood Oxygen feature (iOS 18.6.1 and watchOS 11.6.1, for Apple Watch units
/// sold in the U.S.) measures on the watch and calculates on the paired iPhone. Health then
/// saves the sample with the iPhone as its writer (`HKSourceRevision.productType` "iPhone…")
/// and the watch as its device (`HKDevice.model` "Watch"). Keyed by writer alone, as
/// HealthKit sources are (`hk.<bundle identifier>`), the watch's SpO\u{2082} would land in a
/// "<name>'s iPhone" row beside the watch's own row instead of in it, and Compare would pair
/// the watch's sensor against itself.
///
/// Such a sample is attributed to the watch's own Health source when exactly one source can
/// be that watch, and otherwise stays under its writer as before: two watches that cannot be
/// told apart are never merged by guess. The source id formula is unchanged; only which of
/// the existing ids a relayed sample is filed under changes.
enum HealthKitWatchRelay {
    /// Apple's own Health writers. The iPhone and each paired watch write as
    /// `com.apple.health.<device UUID>`.
    static let appleHealthBundlePrefix = "com.apple.health"

    static func isAppleHealthWriter(bundleIdentifier: String) -> Bool {
        bundleIdentifier.hasPrefix(appleHealthBundlePrefix)
    }

    static func isAppleHealthSource(id: String) -> Bool {
        id.hasPrefix("hk.\(appleHealthBundlePrefix)")
    }

    /// `HKDevice.model` for an Apple Watch is "Watch"; its hardware version is "Watch7,12" and
    /// the like.
    static func isAppleWatch(model: String?) -> Bool {
        model?.caseInsensitiveCompare("Watch") == .orderedSame
    }

    static func isWatchProductType(_ productType: String?) -> Bool {
        productType?.hasPrefix("Watch") == true
    }

    static func isPhoneProductType(_ productType: String?) -> Bool {
        productType?.hasPrefix("iPhone") == true
    }

    /// True for a sample Apple's Health wrote on an iPhone about a measurement whose device is
    /// an Apple Watch. A sample whose writer product type is unknown is not treated as one.
    static func isRelayedWatchMeasurement(
        sourceBundleIdentifier: String,
        sourceProductType: String?,
        deviceModel: String?,
        deviceHardwareVersion: String?
    ) -> Bool {
        isAppleHealthWriter(bundleIdentifier: sourceBundleIdentifier)
            && isPhoneProductType(sourceProductType)
            && (isAppleWatch(model: deviceModel) || isWatchProductType(deviceHardwareVersion))
    }

    /// Whether a stored source is an Apple Watch's own Health writer.
    ///
    /// Product types decide when the source has recorded them. A source stored before they
    /// were recorded falls back to its reported device models, which is what the Devices tab
    /// shows ("HealthKit writer · Watch").
    static func isWatchWriter(_ source: DataSource) -> Bool {
        guard source.transport == .healthKit, isAppleHealthSource(id: source.id) else { return false }
        if let types = source.writerProductTypes, !types.isEmpty {
            return types.contains(where: { isWatchProductType($0) })
                && !types.contains(where: { isPhoneProductType($0) })
        }
        let models = source.observedDeviceModels ?? Set([source.model].compactMap { $0 })
        return models.contains(where: { isAppleWatch(model: $0) })
    }

    /// The one watch source a relayed sample belongs to, or nil when none or several match.
    ///
    /// A watch whose product types are known must match the sample's hardware version; the
    /// sole candidate is accepted without that check only when one of the two is unknown.
    static func watchSource(
        forRelayFrom writerID: String,
        deviceHardwareVersion: String?,
        among sources: [DataSource]
    ) -> DataSource? {
        let candidates = sources.filter { $0.id != writerID && isWatchWriter($0) }
        if let hardware = deviceHardwareVersion, !hardware.isEmpty {
            let exact = candidates.filter { $0.writerProductTypes?.contains(hardware) == true }
            if exact.count == 1 { return exact[0] }
            if exact.count > 1 { return nil }
            let unknown = candidates.filter { ($0.writerProductTypes ?? []).isEmpty }
            return candidates.count == 1 && unknown.count == 1 ? candidates[0] : nil
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Whether every reading already stored under a writer was relayed from a watch, so its
    /// raw history of a metric may follow new samples to the watch's source. True only when
    /// every device the writer reported is an Apple Watch; a writer that also reported another
    /// device keeps its history, because a stored reading no longer says which device it had.
    ///
    /// Called only for a writer whose new samples were just found to be relayed. Such a row
    /// stored before this rule existed reports only "Watch" devices, so `isWatchWriter` would
    /// accept it; a watch product type is what rules a real watch out here.
    static func mayMoveHistory(of writer: DataSource) -> Bool {
        guard writer.transport == .healthKit,
              isAppleHealthSource(id: writer.id),
              !(writer.writerProductTypes ?? []).contains(where: { isWatchProductType($0) }),
              let models = writer.observedDeviceModels, !models.isEmpty
        else { return false }
        return models.allSatisfy({ isAppleWatch(model: $0) })
    }
}
