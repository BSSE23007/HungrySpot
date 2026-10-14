import Foundation
import CommonCrypto
import Security

/// PBKDF2-HMAC-SHA256 with a new cryptographically random salt for every password.
enum PasswordHasher {
    static let iterations = 600_000
    static func validate(_ password: String) throws {
        guard password.count >= 10, password.utf8.count <= 1024 else {
            throw SpotError.validation("Use a password of at least 10 characters (up to 1,024 UTF-8 bytes).")
        }
    }
    static func create(_ password: String) throws -> (hash: Data, salt: Data) {
        try validate(password)
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw SpotError.validation("Secure random data could not be generated. Please try again.") }
        return (try derive(password, salt: salt, rounds: iterations), salt)
    }
    static func verify(_ password: String, hash: Data, salt: Data, rounds: Int) throws -> Bool {
        guard rounds >= 100_000, rounds <= 10_000_000, hash.count == 32, salt.count >= 16, password.utf8.count <= 1024 else { return false }
        let candidate = try derive(password, salt: salt, rounds: rounds)
        var mismatch: UInt8 = 0
        for (a, b) in zip(candidate, hash) { mismatch |= a ^ b }
        return mismatch == 0
    }
    private static func derive(_ password: String, salt: Data, rounds: Int) throws -> Data {
        let bytes = Array(password.utf8)
        var output = Data(count: 32)
        let status: Int32 = bytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: Int8.self).baseAddress, bytes.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard status == kCCSuccess else { throw SpotError.validation("The password could not be secured. Please try again.") }
        return output
    }
}
