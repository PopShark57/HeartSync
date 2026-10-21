import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Uses Apple's on-device model to select complete, deterministically rendered facts.
///
/// Runs entirely on the device: the readings never leave it. Available on iOS 26 and later
/// with Apple Intelligence enabled; elsewhere, and whenever the model declines, fails, or
/// writes something `NowBriefCheck` rejects, there is simply no brief. Builds made with an SDK
/// that has no Foundation Models (CI's Xcode 16) compile the unavailable path only.
enum NowBriefGenerator {
    /// The model selects sentence indices, never medical values or prose.
    static let instructions = """
        Choose up to four of the supplied reading sentences, in their given order.
        Return only their zero-based indices separated by commas, for example: 0,1,2.
        Do not rewrite any reading or add prose.
        """

    /// Sampling temperatures for successive attempts: a draft that fails `NowBriefCheck` is
    /// asked for again a little more freely, and after the last one there is no brief.
    static let attemptTemperatures = [0.2, 0.5, 0.8]

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// The model selects clauses; every displayed character is rendered from the facts.
    static func render(selection: String, facts: NowBriefFacts) -> String? {
        let tokens = selection.split(separator: ",", omittingEmptySubsequences: false)
        let indices = tokens.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard indices.count == tokens.count, (1...4).contains(indices.count),
              indices == indices.sorted(), Set(indices).count == indices.count,
              indices.allSatisfy({ facts.items.indices.contains($0) }) else { return nil }
        return NowBriefCheck.accepted(indices.map { facts.items[$0].sentence }.joined(separator: " "), facts: facts)
    }

    /// The accepted brief for `facts`, or nil.
    static func generate(_ facts: NowBriefFacts) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            for temperature in attemptTemperatures {
                guard !Task.isCancelled else { return nil }
                // A fresh session each time, so a rejected draft is not part of the context.
                let session = LanguageModelSession(instructions: instructions)
                do {
                    let response = try await session.respond(
                        to: facts.lines.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n"),
                        options: GenerationOptions(temperature: temperature, maximumResponseTokens: 140)
                    )
                    if let accepted = render(selection: response.content, facts: facts) { return accepted }
                } catch {
                    // A guardrail refusal, an unsupported language, or a busy model: no brief.
                    return nil
                }
            }
            return nil
        }
        #endif
        return nil
    }
}
