import Foundation

/// Runs `MacMirrorPairing` over a channel, for either side.
///
/// After the keys are exchanged both screens show the code. Each side sends its confirmation
/// as soon as its own person confirms, and finishes once it also holds a valid confirmation
/// from the other side. A decline on either device sends `pairCancel` and ends both.
enum MacMirrorPairingExchange {
    /// Asks this device's person whether `code` matches the other screen. Should return
    /// false promptly when its task is cancelled (the other device declined).
    typealias Confirm = @MainActor @Sendable (_ code: String, _ peer: MacMirrorPairing.Identity) async -> Bool

    static var declined: MacMirrorError {
        .pairing(String(
            localized: "macMirror.pairing.declined",
            defaultValue: "Pairing was cancelled.",
            comment: "Mac pairing ended because a person declined or cancelled it"
        ))
    }

    static var declinedByPeer: MacMirrorError {
        .pairing(String(
            localized: "macMirror.pairing.declinedByPeer",
            defaultValue: "Pairing was cancelled on the other device.",
            comment: "Mac pairing ended because the person on the other device declined"
        ))
    }

    /// The phone's side. Returns the record to keep.
    static func runPhone(
        channel: any MacMirrorFrameChannel,
        identity: MacMirrorPairing.Identity,
        handshakeTimeout: Duration = .seconds(30),
        confirmationTimeout: Duration = .seconds(120),
        confirm: @escaping Confirm
    ) async throws -> MacMirrorPairingRecord {
        let initiator = MacMirrorPairing.Initiator(identity: identity)
        try await channel.send(.json(.pairCommit, initiator.commit))
        let share = try await expect(.pairKey, MacMirrorPairing.KeyShare.self, from: channel, timeout: handshakeTimeout)
        let (reveal, agreement) = try initiator.receive(share)
        try await channel.send(.json(.pairReveal, reveal))
        try await settle(agreement, role: .phone, peer: agreement.mac, channel: channel, timeout: confirmationTimeout, confirm: confirm)
        return MacMirrorPairingRecord(agreement: agreement, role: .phone)
    }

    /// The Mac's side. Returns the record to keep.
    static func runMac(
        channel: any MacMirrorFrameChannel,
        identity: MacMirrorPairing.Identity,
        handshakeTimeout: Duration = .seconds(30),
        confirmationTimeout: Duration = .seconds(120),
        confirm: @escaping Confirm
    ) async throws -> MacMirrorPairingRecord {
        var responder = MacMirrorPairing.Responder(identity: identity)
        let commit = try await expect(.pairCommit, MacMirrorPairing.Commit.self, from: channel, timeout: handshakeTimeout)
        try await channel.send(.json(.pairKey, try responder.receive(commit)))
        let reveal = try await expect(.pairReveal, MacMirrorPairing.Reveal.self, from: channel, timeout: handshakeTimeout)
        let agreement = try responder.receive(reveal)
        try await settle(agreement, role: .mac, peer: agreement.phone, channel: channel, timeout: confirmationTimeout, confirm: confirm)
        return MacMirrorPairingRecord(agreement: agreement, role: .mac)
    }

    private enum Step: Sendable {
        case timeout
        case person(Bool)
        case peer(Result<MacMirrorFrame, MacMirrorError>)
    }

    /// Waits for this device's person and the other device's confirmation, in either order.
    private static func settle(
        _ agreement: MacMirrorPairing.Agreement,
        role: MacMirrorPairing.Role,
        peer: MacMirrorPairing.Identity,
        channel: any MacMirrorFrameChannel,
        timeout: Duration,
        confirm: @escaping Confirm
    ) async throws {
        let otherRole: MacMirrorPairing.Role = role == .phone ? .mac : .phone
        let code = agreement.displayCode
        let ownConfirmation = agreement.confirmation(from: role)
        let failure: MacMirrorError? = await withTaskGroup(of: Step.self) { group in
            group.addTask { .person(await confirm(code, peer)) }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return .timeout }
                return .timeout
            }
            group.addTask {
                do { return .peer(.success(try await channel.receive())) }
                catch let error as MacMirrorError { return .peer(.failure(error)) }
                catch { return .peer(.failure(.connectionFailed(error.localizedDescription))) }
            }
            var confirmedHere = false
            var confirmedThere = false
            while let step = await group.next() {
                switch step {
                case .timeout:
                    channel.cancel()
                    group.cancelAll()
                    return .timedOut
                case .person(true):
                    confirmedHere = true
                    do { try await channel.send(.json(.pairConfirm, ownConfirmation)) }
                    catch {
                        channel.cancel()
                        group.cancelAll()
                        return (error as? MacMirrorError) ?? .closed
                    }
                case .person(false):
                    try? await channel.send(MacMirrorFrame(type: .pairCancel, body: Data()))
                    channel.cancel()
                    group.cancelAll()
                    return declined
                case .peer(.success(let frame)) where frame.type == .pairConfirm:
                    guard let confirmation = try? frame.decode(.pairConfirm, as: MacMirrorPairing.Confirmation.self),
                          agreement.verifies(confirmation, from: otherRole)
                    else {
                        channel.cancel()
                        group.cancelAll()
                        return MacMirrorError.pairing(String(
                            localized: "macMirror.pairing.badConfirmation",
                            defaultValue: "The other device's confirmation did not check out. Pairing was stopped.",
                            comment: "Mac pairing failed: the other side's confirmation was invalid"
                        ))
                    }
                    confirmedThere = true
                case .peer(.success(let frame)):
                    channel.cancel()
                    group.cancelAll()
                    return frame.type == .pairCancel
                        ? declinedByPeer
                        : MacMirrorError.malformed("expected a confirmation, received \(frame.type)")
                case .peer(.failure(let error)):
                    group.cancelAll()
                    return error
                }
                if confirmedHere && confirmedThere { group.cancelAll(); return nil }
            }
            return MacMirrorError.closed
        }
        if let failure { throw failure }
    }

    private static func expect<T: Decodable>(
        _ type: MacMirrorFrameType,
        _: T.Type,
        from channel: any MacMirrorFrameChannel,
        timeout: Duration
    ) async throws -> T {
        let frame = try await channel.receive(timeout: timeout)
        if frame.type == .pairCancel { throw declinedByPeer }
        return try frame.decode(type, as: T.self)
    }
}
