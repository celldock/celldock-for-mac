import AppKit
import Foundation

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    private let updaterManager = UpdaterManager.shared
    private var menuBarPanelController: MenuBarPanelController?
    private weak var appState: AppState?
    private var didFinishLaunching = false
    private var didShowInitialCommunicationWindow = false
    private var didScheduleStartupPermissionRequest = false

    func configure(appState: AppState) {
        self.appState = appState
        menuBarPanelController = MenuBarPanelController(appState: appState)
        if didFinishLaunching {
            menuBarPanelController?.start()
            showInitialCommunicationWindowIfNeeded()
            scheduleStartupPermissionRequestIfNeeded()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearanceMode.storedPreference.apply()
        updaterManager.start()
        didFinishLaunching = true
        menuBarPanelController?.start()
        showInitialCommunicationWindowIfNeeded()
        scheduleStartupPermissionRequestIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarPanelController?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTerminationCoordinator.shared.beginTermination(of: sender)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            CommunicationWindowController.shared.handleApplicationReopen()
        }
        return true
    }

    private func showInitialCommunicationWindowIfNeeded() {
        guard !didShowInitialCommunicationWindow, let appState else { return }
        didShowInitialCommunicationWindow = true
        DispatchQueue.main.async {
            appState.showMessagesWindow()
        }
    }

    private func scheduleStartupPermissionRequestIfNeeded() {
        guard !didScheduleStartupPermissionRequest else { return }
        didScheduleStartupPermissionRequest = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.appState?.requestStartupPermissionsIfNeeded()
        }
    }
}
