import Foundation
import Security

/// TLS trust for SM-DP+ (ES9+) servers.
///
/// Many SM-DP+ servers present TLS certificates issued directly by the GSMA RSP2
/// root CI rather than a public web CA, so macOS rejects them by default. Accept a
/// server when either the system trust store or a bundled GSMA root vouches for it,
/// keeping the SSL policy's hostname, validity and chain checks in both cases.
enum EUICCServerTrust {
    /// GSM Association - RSP2 Root CI1 (production), valid until 2052-02-21.
    /// SHA-256 5E3E91FD454327C3AF5D32A7A73BBC59FE43AA7D85FD32D5DB44423F80A56BB3,
    /// SKI 81370F5125D0B1D408D4C3B232E6D25E795BEBFB (the eUICC CI PKID).
    /// Matches ChromiumOS hermes/certs/prod/gsma-ci.pem.
    static let gsmaRootCertificateBase64 = """
        MIICSTCCAe+gAwIBAgIQbmhWeneg7nyF7hg5Y9+qejAKBggqhkjOPQQDAjBEMRgwFgYDVQQKEw9H
        U00gQXNzb2NpYXRpb24xKDAmBgNVBAMTH0dTTSBBc3NvY2lhdGlvbiAtIFJTUDIgUm9vdCBDSTEw
        IBcNMTcwMjIyMDAwMDAwWhgPMjA1MjAyMjEyMzU5NTlaMEQxGDAWBgNVBAoTD0dTTSBBc3NvY2lh
        dGlvbjEoMCYGA1UEAxMfR1NNIEFzc29jaWF0aW9uIC0gUlNQMiBSb290IENJMTBZMBMGByqGSM49
        AgEGCCqGSM49AwEHA0IABJ1qutL0HCMX52GJ6/jeibsAqZfULWj/X10p/Min6seZN+hf5llovbCN
        uB2nunLz+O8UD0SUCBUVo8e6n9X1TuajgcAwgb0wDgYDVR0PAQH/BAQDAgEGMA8GA1UdEwEB/wQF
        MAMBAf8wEwYDVR0RBAwwCogIKwYBBAGC6WAwFwYDVR0gAQH/BA0wCzAJBgdngRIBAgEAME0GA1Ud
        HwRGMEQwQqBAoD6GPGh0dHA6Ly9nc21hLWNybC5zeW1hdXRoLmNvbS9vZmZsaW5lY2EvZ3NtYS1y
        c3AyLXJvb3QtY2kxLmNybDAdBgNVHQ4EFgQUgTcPUSXQsdQI1MOyMubSXnlb6/swCgYIKoZIzj0E
        AwIDSAAwRQIgIJdYsOMFWziPK7l8nh5mu0qiRiVf25oa9ullG/OIASwCIQDqCmDrYf+GziHXBOiw
        JwnBaeBOaFsiLzIEOaUuZwdNUw==
        """

    static let gsmaRootCertificates: [SecCertificate] = {
        guard let data = Data(base64Encoded: gsmaRootCertificateBase64, options: .ignoreUnknownCharacters),
              let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            return []
        }
        return [certificate]
    }()

    /// Returns the trust object to answer the challenge with, or nil to reject it.
    static func evaluate(_ serverTrust: SecTrust, host: String) -> SecTrust? {
        if SecTrustEvaluateWithError(serverTrust, nil) {
            return serverTrust
        }
        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            return nil
        }
        return gsmaTrust(for: chain, host: host)
    }

    /// Evaluates `certificates` (leaf first) against the bundled GSMA roots only.
    static func gsmaTrust(
        for certificates: [SecCertificate],
        host: String,
        verifyDate: Date? = nil
    ) -> SecTrust? {
        guard !certificates.isEmpty, !gsmaRootCertificates.isEmpty else { return nil }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
              let trust,
              SecTrustSetAnchorCertificates(trust, gsmaRootCertificates as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else {
            return nil
        }
        if let verifyDate, SecTrustSetVerifyDate(trust, verifyDate as CFDate) != errSecSuccess {
            return nil
        }
        return SecTrustEvaluateWithError(trust, nil) ? trust : nil
    }
}
