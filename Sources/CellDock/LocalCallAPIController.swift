import AppKit
import Combine
import Foundation
import Security

@MainActor
final class LocalCallAPIController: ObservableObject {
    static let endpoint = "http://127.0.0.1:7576"
    private static let enabledKey = "LocalCallAPIEnabled.v1"
    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    private weak var appState: AppState?
    private var server: LocalCallAPIServer?
    private var generation: UUID?
    private var token: String?

    init(appState: AppState) { self.appState = appState }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    func start() {
        guard isEnabled, server == nil, !AppTerminationCoordinator.shared.isTerminationPending else { return }
        error = nil
        do {
            let token = try LocalCallAPICredentialStore.loadOrCreate()
            self.token = token
            let generation = UUID()
            self.generation = generation
            let server = LocalCallAPIServer(token: token) { [weak self] command, completion in
                guard let self, self.generation == generation, self.isEnabled,
                      let appState = self.appState else {
                    completion(.error(503, "Local call API is stopped"))
                    return
                }
                if command == .status {
                    completion(.json(LocalCallAPIStatus(appState: appState)))
                    return
                }
                let completed: (ModemActionResult) -> Void = { result in
                    switch result {
                    case .success:
                        completion(.json(LocalCallAPIActionResponse(accepted: true,
                            call: LocalCallAPIStatus(appState: appState))))
                    case .failure(let message): completion(.error(409, message))
                    }
                }
                switch command {
                case .dial(let number): appState.dial(number, completion: completed)
                case .answer: appState.answerCall(completion: completed)
                case .hangUp: appState.hangUp(completion: completed)
                case .status: break
                }
            }
            self.server = server
            try server.start { [weak self] error in
                guard let self, self.generation == generation else { return }
                self.isRunning = error == nil
                self.error = error
                if error != nil {
                    self.server?.stop()
                    self.server = nil
                    self.generation = nil
                }
            }
        } catch {
            stop()
            self.error = error.localizedDescription
        }
    }

    func stop() {
        generation = nil
        server?.stop()
        server = nil
        token = nil
        isRunning = false
        error = nil
    }

    func copyToken() {
        guard isRunning, let token else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }
}

private struct LocalCallAPIActionResponse: Encodable {
    let accepted: Bool
    let call: LocalCallAPIStatus
}

private extension LocalCallAPIStatus {
    @MainActor init(appState: AppState) {
        self.init(call: appState.call, isChangingCall: appState.isChangingCall)
    }
}

private enum LocalCallAPICredentialStore {
    static func loadOrCreate() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.celldock.mac.local-call-api",
            kSecAttrAccount as String: "bearer-token",
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new } as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let token = String(data: data, encoding: .utf8), !token.isEmpty { return token }
        guard status == errSecItemNotFound else { throw keychainError(status) }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw keychainError(randomStatus) }
        let token = Data(bytes).base64EncodedString()
        let added = SecItemAdd(query.merging([
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw keychainError(added) }
        return token
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        ])
    }
}
