import CommonCrypto
import Foundation
import Security

enum LegacyEncryptionSupport {
    static let verifySalt = Data("Salt for verifying master key in a single iteration".utf8)
    static let keychainServiceName = "Notational Velocity"
    static let defaultHashIterations = 8000
    static let defaultKeyLengthInBits = 256

    static func randomData(length: Int) -> Data? {
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, length, buffer.baseAddress!)
        }
        return status == errSecSuccess ? data : nil
    }

    static func deriveKey(passphraseData: Data, salt: Data, keyLengthInBytes: Int, iterations: Int) -> Data? {
        var derived = Data(count: keyLengthInBytes)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passphraseData.withUnsafeBytes { passphraseBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passphraseBytes.bindMemory(to: Int8.self).baseAddress,
                        passphraseData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(iterations),
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLengthInBytes
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    static func verifierKey(for masterKey: Data, keyLengthInBytes: Int) -> Data? {
        deriveKey(passphraseData: masterKey, salt: verifySalt, keyLengthInBytes: keyLengthInBytes, iterations: 1)
    }

    static func verify(passphraseData: Data, prefs: LegacyNotationPrefsArchive) -> Data? {
        let keyLengthInBytes = max(16, prefs.keyLengthInBits / 8)
        guard let masterSalt = prefs.masterSalt,
              let verifierKey = prefs.verifierKey,
              let masterKey = deriveKey(
                passphraseData: passphraseData,
                salt: masterSalt,
                keyLengthInBytes: keyLengthInBytes,
                iterations: max(1, prefs.hashIterationCount)
              ),
              let computedVerifier = self.verifierKey(for: masterKey, keyLengthInBytes: keyLengthInBytes),
              computedVerifier == verifierKey else {
            return nil
        }
        return masterKey
    }

    static func encrypt(_ data: Data, masterKey: Data, prefs: LegacyNotationPrefsArchive) -> (ciphertext: Data, dataSessionSalt: Data)? {
        let keyLengthInBytes = max(16, prefs.keyLengthInBits / 8)
        guard let dataSessionSalt = randomData(length: 256),
              let sessionKey = deriveKey(
                passphraseData: masterKey,
                salt: dataSessionSalt,
                keyLengthInBytes: keyLengthInBytes,
                iterations: 1
              ) else {
            return nil
        }
        let iv = dataSessionSalt.prefix(16)
        guard let encrypted = crypt(data: data, key: sessionKey, iv: iv, operation: CCOperation(kCCEncrypt)) else {
            return nil
        }
        return (encrypted, dataSessionSalt)
    }

    static func decrypt(_ data: Data, masterKey: Data, prefs: LegacyNotationPrefsArchive) -> Data? {
        let keyLengthInBytes = max(16, prefs.keyLengthInBits / 8)
        guard let dataSessionSalt = prefs.dataSessionSalt,
              dataSessionSalt.count >= 16,
              let sessionKey = deriveKey(
                passphraseData: masterKey,
                salt: dataSessionSalt,
                keyLengthInBytes: keyLengthInBytes,
                iterations: 1
              ) else {
            return nil
        }
        let iv = dataSessionSalt.prefix(16)
        return crypt(data: data, key: sessionKey, iv: iv, operation: CCOperation(kCCDecrypt))
    }

    static func keychainPassphraseData(identifier: String) -> Data? {
        guard !identifier.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func storeKeychainPassphraseData(_ data: Data, identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: identifier
        ]

        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            return false
        }

        var create = query
        create[kSecValueData as String] = data
        return SecItemAdd(create as CFDictionary, nil) == errSecSuccess
    }

    static func removeKeychainPassphraseData(identifier: String) {
        guard !identifier.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: identifier
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func generatedKeychainIdentifier() -> String {
        UUID().uuidString
    }

    private static func crypt(data: Data, key: Data, iv: Data, operation: CCOperation) -> Data? {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count

        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        output.count = outputLength
        return output
    }
}
