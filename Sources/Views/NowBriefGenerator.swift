import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns `NowBriefFacts` into a short paragraph with Apple's on-device language model.
///
/// Runs entirely on the device: the readings never leave it. Available on iOS 26 and later
/// with Apple Intelligence enabled; elsewhere, and whenever the model declines, fails, or
/// writes something `NowBriefCheck` rejects, there is simply no brief. Builds made with an SDK
/// that has no Foundation Models (CI's Xcode 16) compile the unavailable path only.
enum NowBriefGenerator {
    /// The model's standing instructions. The rules restate what every card already does:
    /// estimates stay estimates, old readings keep their age, and nothing is diagnosed.
    static let instructions = """
        Summarise the readings below for the top of a health dashboard, in two or three flowing sentences under 55 words.
        Include each value and unit exactly as given, in the order given. Readings after the fourth may be joined into one short clause or left out.
        Call a reading an estimate only if its line says "Estimated", and always if it does. Keep the time since a reading was last reported wherever the readings give it.
        Add nothing: no other numbers, no judgement of whether a value is good or bad, no advice, no diagnosis, no causes.
        No greeting, list, or headings.

        Example readings:
        - Heart rate is 64 bpm now.
        - Estimated blood pressure was 121/79 mmHg when last reported, 4 hours ago.
        - Blood oxygen was 98% when last reported, 5 hours ago.
        Example summary: Your heart rate is 64 bpm right now. Estimated blood pressure was 121/79 mmHg 4 hours ago, and blood oxygen was 98% 5 hours ago.
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
                        to: facts.prompt,
                        options: GenerationOptions(temperature: temperature, maximumResponseTokens: 140)
                    )
                    if let accepted = NowBriefCheck.accepted(response.content, facts: facts) { return accepted }
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
