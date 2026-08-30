import Foundation
import CryptoKit

extension UUID {
    /// Derives a deterministic UUID from a string.
    ///
    /// Used so that re-fetching the same record from a remote source (an Oura sample id,
    /// a HealthKit sample UUID re-delivered after an anchor reset) produces the same
    /// `Reading.id` every time and therefore de-duplicates instead of piling up.
    init(stableFrom string: String) {
        let digest = SHA256.hash(data: Data(string.utf8))
        var bytes = [UInt8](digest.prefix(16))
        // Stamp version 5 / RFC 4122 variant so this is a well-formed name-based UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        self = UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
