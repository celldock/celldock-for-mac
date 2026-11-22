import AppKit
import CModemBridge
import Darwin
import Foundation

struct USBInterfaceReleaseResult {
    let ownerName: String
    let processID: pid_t
    let terminated: Bool

    var message: String {
        if terminated {
            return L10n.tr(
                "已结束占用模块控制接口的 %@（PID %lld）。",
                ownerName,
                Int64(processID)
            )
        }
        return L10n.tr(
            "无法结束占用模块控制接口的 %@（PID %lld）。",
            ownerName,
            Int64(processID)
        )
    }
}

struct USBInterfaceOwner: Equatable {
    let processName: String
    let processID: pid_t
}

enum USBInterfaceContentionResolver {
    static func adbInterfaceOwner(locationID: UInt32) -> USBInterfaceOwner? {
        var processID: Int32 = 0
        var nameBytes = [CChar](repeating: 0, count: 192)
        let found = nameBytes.withUnsafeMutableBufferPointer { buffer in
            celldock_usb_interface_owner_process(
                locationID,
                6,
                &processID,
                buffer.baseAddress,
                buffer.count
            )
        }
        guard found == 1, processID > 0 else { return nil }
        let ownerName = String(cString: nameBytes)
        return USBInterfaceOwner(processName: ownerName, processID: pid_t(processID))
    }

    static func forceReleaseADBInterface(locationID: UInt32) -> USBInterfaceReleaseResult? {
        guard let owner = adbInterfaceOwner(locationID: locationID) else { return nil }
        let ownerName = owner.processName
        let pid = owner.processID
        guard pid != getpid() else {
            return USBInterfaceReleaseResult(
                ownerName: ownerName,
                processID: pid,
                terminated: false
            )
        }

        let runningApplication = NSRunningApplication(processIdentifier: pid)
        _ = runningApplication?.terminate()
        if waitForProcessExit(pid, timeout: 1.0) {
            return USBInterfaceReleaseResult(
                ownerName: ownerName,
                processID: pid,
                terminated: true
            )
        }
        _ = runningApplication?.forceTerminate()
        if waitForProcessExit(pid, timeout: 0.5) {
            return USBInterfaceReleaseResult(
                ownerName: ownerName,
                processID: pid,
                terminated: true
            )
        }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else {
            return USBInterfaceReleaseResult(
                ownerName: ownerName,
                processID: pid,
                terminated: false
            )
        }
        if waitForProcessExit(pid, timeout: 1.0) {
            return USBInterfaceReleaseResult(
                ownerName: ownerName,
                processID: pid,
                terminated: true
            )
        }
        guard kill(pid, SIGKILL) == 0 || errno == ESRCH else {
            return USBInterfaceReleaseResult(
                ownerName: ownerName,
                processID: pid,
                terminated: false
            )
        }
        return USBInterfaceReleaseResult(
            ownerName: ownerName,
            processID: pid,
            terminated: waitForProcessExit(pid, timeout: 1.0)
        )
    }

    private static func waitForProcessExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while processExists(pid), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !processExists(pid)
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        errno = 0
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
