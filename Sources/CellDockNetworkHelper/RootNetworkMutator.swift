import Foundation
import IOKit
import IOKit.network
import IOKit.usb
import CellDockNetworkIPC
import OSLog
import SystemConfiguration

private let rootNetworkLogger = Logger(
    subsystem: "app.celldock.mac.network.helper",
    category: "CellularNetwork"
)

struct HelperActionResult {
    let code: CellDockNetworkResultCode
    let succeeded: Bool
    let message: String

    static func success(_ message: String) -> HelperActionResult {
        HelperActionResult(code: .success, succeeded: true, message: message)
    }

    static func failure(
        _ message: String,
        code: CellDockNetworkResultCode = .failure
    ) -> HelperActionResult {
        HelperActionResult(code: code, succeeded: false, message: message)
    }
}

final class RootNetworkMutator {
    private let stateStore = NetworkHelperStateStore()

    func applyCellularNetworkConfiguration(
        _ request: CellularNetworkConfigurationRequest
    ) -> HelperActionResult {
        guard geteuid() == 0 else {
            return .failure("网络 helper 没有以 root 身份运行，已拒绝修改。")
        }
        guard request.isValid else {
            return .failure("蜂窝网络配置包含重复或冲突的模组。")
        }
        for locationID in request.enabledLocationIDs
        where findLiveModemInterface(locationID: locationID) == nil {
            return .failure(
                "没有找到位置 0x\(String(locationID, radix: 16)) 的 CDC-ECM 接口。"
            )
        }

        guard let preferences = SCPreferencesCreate(
            nil,
            "CellDock Network Helper" as NSString,
            nil
        ) else {
            return .failure(systemConfigurationError("无法建立网络配置会话"))
        }
        guard SCPreferencesLock(preferences, true) else {
            return .failure(systemConfigurationError("系统网络配置正被其他程序占用"))
        }
        var preferencesLocked = true
        defer {
            if preferencesLocked { SCPreferencesUnlock(preferences) }
        }
        guard let networkSet = SCNetworkSetCopyCurrent(preferences),
              let setID = SCNetworkSetGetSetID(networkSet) as String? else {
            return .failure(systemConfigurationError("找不到当前网络位置"))
        }

        var state = stateStore.load()
        let originalState = state
        var serviceByLocation: [UInt32: SCNetworkService] = [:]
        var newlyEnabledLocations: Set<UInt32> = []

        for locationID in request.enabledLocationIDs {
            let service: SCNetworkService
            if let existing = findLiveModemService(in: networkSet, locationID: locationID) {
                service = existing
            } else {
                guard let interface = findLiveModemInterface(locationID: locationID),
                      let created = SCNetworkServiceCreate(preferences, interface),
                      SCNetworkServiceEstablishDefaultConfiguration(created),
                      SCNetworkServiceSetName(
                          created,
                          serviceName(for: interface, locationID: locationID) as NSString
                      ),
                      SCNetworkSetAddService(networkSet, created) else {
                    return .failure(systemConfigurationError("无法创建模组网络服务"))
                }
                service = created
                newlyEnabledLocations.insert(locationID)
            }
            if !SCNetworkServiceGetEnabled(service) {
                newlyEnabledLocations.insert(locationID)
            }
            serviceByLocation[locationID] = service
        }

        for locationID in request.offLocationIDs where serviceByLocation[locationID] == nil {
            serviceByLocation[locationID] =
                findLiveModemService(in: networkSet, locationID: locationID) ??
                recordedService(
                    in: networkSet,
                    state: state,
                    locationID: locationID
                )
        }

        let allServices = services(in: networkSet)
        for service in allServices {
            guard let interface = SCNetworkServiceGetInterface(service),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let identity = usbIdentity(forBSDName: bsdName),
                  matchesTargetModem(identity, locationID: 0),
                  let locationID = identity.locationID else { continue }
            serviceByLocation[locationID] = service
        }

        // Every USB re-enumeration that lands on a fresh BSD name leaves the old
        // modem service behind, still enabled and still sitting among the
        // non-cellular services. Their hardware is gone, so the IORegistry can no
        // longer identify them; fall back to the interface's persisted vendor
        // name so they can be ordered, disabled, and pruned like any other
        // cellular service instead of accumulating forever.
        let claimedServiceIDs = Set(serviceByLocation.values.compactMap {
            SCNetworkServiceGetServiceID($0) as String?
        })
        let liveBSDNames = Set(
            ((SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [])
                .compactMap { SCNetworkInterfaceGetBSDName($0) as String? }
        )
        var abandonedServices: [SCNetworkService] = []
        for service in allServices {
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                  !claimedServiceIDs.contains(serviceID),
                  let interface = SCNetworkServiceGetInterface(service),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  usbIdentity(forBSDName: bsdName) == nil,
                  isKnownModemInterfaceName(
                      SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
                  ) else { continue }
            // Only treat it as abandoned when the BSD interface is absent from the
            // whole system. A transient IORegistry miss on a still-attached module
            // must never cost the user their live service.
            guard !liveBSDNames.contains(bsdName) else { continue }
            abandonedServices.append(service)
        }

        var records = state.serviceRecordsByLocation ?? [:]
        for (locationID, service) in serviceByLocation {
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                  let interface = SCNetworkServiceGetInterface(service),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                continue
            }
            records[String(locationID)] = NetworkServiceRecord(
                setID: setID,
                serviceID: serviceID,
                bsdName: bsdName
            )
        }
        state.serviceRecordsByLocation = records

        let currentOrder = completeServiceOrder(networkSet)
        let originalOrder: [String]
        if let saved = state.configurationSnapshot,
           saved.setID == setID,
           relativeOrderMatches(currentOrder, saved.applied) {
            originalOrder = saved.original
        } else if let legacy = state.orderSnapshot,
                  legacy.setID == setID,
                  relativeOrderMatches(currentOrder, legacy.promoted) {
            originalOrder = legacy.original
        } else {
            originalOrder = currentOrder
        }

        let preferredServiceID = request.preferredLocationID.flatMap {
            serviceByLocation[$0].flatMap { SCNetworkServiceGetServiceID($0) as String? }
        }
        let standbyServiceIDs = request.standbyLocationIDs.compactMap {
            serviceByLocation[$0].flatMap { SCNetworkServiceGetServiceID($0) as String? }
        }
        // A detached module's leftover service cannot be identified through the
        // IORegistry any more, so fall back to the persisted records. Without
        // this it would be classified as non-cellular and ordered ahead of the
        // standby modules that are actually present.
        let liveCellularServiceIDs = Set(serviceByLocation.values.compactMap {
            SCNetworkServiceGetServiceID($0) as String?
        })
        let knownServiceIDs = Set(currentOrder)
        let recordedCellularServiceIDs = Set(
            records.values
                .filter { $0.setID == setID && knownServiceIDs.contains($0.serviceID) }
                .map(\.serviceID)
        )
        let abandonedServiceIDs = Set(abandonedServices.compactMap {
            SCNetworkServiceGetServiceID($0) as String?
        })
        let cellularServiceIDs = liveCellularServiceIDs
            .union(recordedCellularServiceIDs)
            .union(abandonedServiceIDs)
        let enabledServiceIDs = Set(([preferredServiceID].compactMap { $0 }) + standbyServiceIDs)

        let appliedOrder: [String]
        let isTurningEverythingOff = enabledServiceIDs.isEmpty
        if isTurningEverythingOff,
           let saved = state.configurationSnapshot,
           saved.setID == setID,
           relativeOrderMatches(currentOrder, saved.applied) {
            let currentIDs = Set(currentOrder)
            let restored = saved.original.filter(currentIDs.contains)
            appliedOrder = restored + currentOrder.filter { !restored.contains($0) }
            state.configurationSnapshot = nil
            state.orderSnapshot = nil
        } else if isTurningEverythingOff,
                  let legacy = state.orderSnapshot,
                  legacy.setID == setID,
                  relativeOrderMatches(currentOrder, legacy.promoted) {
            let currentIDs = Set(currentOrder)
            let restored = legacy.original.filter(currentIDs.contains)
            appliedOrder = restored + currentOrder.filter { !restored.contains($0) }
            state.orderSnapshot = nil
        } else {
            appliedOrder = CellularNetworkServiceOrderPolicy.appliedOrder(
                preferredServiceID: preferredServiceID,
                standbyServiceIDs: standbyServiceIDs,
                originalOrder: originalOrder,
                cellularServiceIDs: cellularServiceIDs
            )
            state.configurationSnapshot = NetworkConfigurationSnapshot(
                setID: setID,
                original: originalOrder,
                applied: appliedOrder
            )
            state.orderSnapshot = nil
        }

        let mutatedServices = Array(serviceByLocation.values) + abandonedServices
        var originalEnabledStates: [String: Bool] = [:]
        for service in mutatedServices {
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
                continue
            }
            originalEnabledStates[serviceID] = SCNetworkServiceGetEnabled(service)
        }
        do {
            try stateStore.save(state)
        } catch {
            return .failure("无法保存网络配置恢复记录：\(error.localizedDescription)")
        }

        let servicesUpdated = mutatedServices.allSatisfy { service in
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
                return false
            }
            return SCNetworkServiceSetEnabled(service, enabledServiceIDs.contains(serviceID))
        }
        guard servicesUpdated,
              SCNetworkSetSetServiceOrder(networkSet, appliedOrder as NSArray) else {
            for service in mutatedServices {
                guard let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                      let wasEnabled = originalEnabledStates[serviceID] else { continue }
                _ = SCNetworkServiceSetEnabled(service, wasEnabled)
            }
            _ = SCNetworkSetSetServiceOrder(networkSet, currentOrder as NSArray)
            try? stateStore.save(originalState)
            return .failure(systemConfigurationError("无法应用多模组蜂窝网络配置"))
        }

        // Pruned last so a failure above still rolls back cleanly. Removing them
        // loses nothing: the mode lives in app preferences keyed by IMEI, and a
        // reattached module gets a freshly configured service.
        var didPruneService = false
        for service in abandonedServices {
            guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
                continue
            }
            if SCNetworkSetRemoveService(networkSet, service) {
                rootNetworkLogger.notice(
                    "Removed abandoned modem service \(serviceID, privacy: .public)"
                )
                records = records.filter { $0.value.serviceID != serviceID }
                didPruneService = true
            } else {
                rootNetworkLogger.error(
                    "Could not remove abandoned modem service \(serviceID, privacy: .public)"
                )
            }
        }
        if didPruneService {
            state.serviceRecordsByLocation = records
            try? stateStore.save(state)
        }
        guard SCPreferencesCommitChanges(preferences) else {
            try? stateStore.save(originalState)
            return .failure(systemConfigurationError("保存系统网络配置失败"))
        }
        guard SCPreferencesApplyChanges(preferences) else {
            return .failure(systemConfigurationError("应用系统网络配置失败"))
        }
        SCPreferencesUnlock(preferences)
        preferencesLocked = false

        // Every enabled module gets its turn. Returning at the first failure
        // left the remaining modules without a DHCP attempt, so one dead
        // module kept healthy ones offline too.
        var firstFailure: HelperActionResult?
        for locationID in request.enabledLocationIDs {
            guard let service = serviceByLocation[locationID],
                  let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                  let interface = SCNetworkServiceGetInterface(service),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                continue
            }
            let needsDHCP = newlyEnabledLocations.contains(locationID) ||
                currentDHCPLease(serviceID: serviceID) == nil
            if needsDHCP,
               let failure = establishDHCP(
                   serviceID: serviceID,
                   interface: interface,
                   on: bsdName,
                   locationID: locationID
               ) {
                rootNetworkLogger.error(
                    "Module network bring-up failed location=\(locationID, privacy: .public) reason=\(failure.message, privacy: .public)"
                )
                if firstFailure == nil {
                    firstFailure = .failure(
                        "模组 0x\(String(locationID, radix: 16)) 已启用，但 \(failure.message)",
                        code: failure.code
                    )
                }
            }
        }
        if let firstFailure { return firstFailure }

        if isTurningEverythingOff {
            return .success("已关闭所有蜂窝网络服务，并恢复原网络顺序。")
        }
        return .success(
            "已应用蜂窝网络配置：优先 \(preferredServiceID == nil ? 0 : 1) 个，保持连接 \(standbyServiceIDs.count) 个。"
        )
    }

    private func services(in networkSet: SCNetworkSet) -> [SCNetworkService] {
        guard let rawServices = SCNetworkSetCopyServices(networkSet) else { return [] }
        return (rawServices as? [SCNetworkService]) ?? []
    }

    private func findLiveModemService(
        in networkSet: SCNetworkSet,
        locationID: UInt32
    ) -> SCNetworkService? {
        services(in: networkSet).first { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  (SCNetworkInterfaceGetInterfaceType(interface) as String?) ==
                    (kSCNetworkInterfaceTypeEthernet as String),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                return false
            }
            return matchesTargetModem(
                usbIdentity(forBSDName: bsdName),
                locationID: locationID
            )
        }
    }

    private func recordedService(
        in networkSet: SCNetworkSet,
        state: NetworkHelperState,
        locationID: UInt32
    ) -> SCNetworkService? {
        let record = state.serviceRecordsByLocation?[String(locationID)] ?? state.serviceRecord
        guard let record,
              (SCNetworkSetGetSetID(networkSet) as String?) == record.setID else {
            return nil
        }
        return services(in: networkSet).first { service in
            guard (SCNetworkServiceGetServiceID(service) as String?) == record.serviceID,
                  let interface = SCNetworkServiceGetInterface(service),
                  (SCNetworkInterfaceGetBSDName(interface) as String?) == record.bsdName else {
                return false
            }
            return matchesTargetModem(
                usbIdentity(forBSDName: record.bsdName),
                locationID: locationID
            )
        }
    }

    private func findLiveModemInterface(locationID: UInt32) -> SCNetworkInterface? {
        let interfaces = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        return interfaces.first { interface in
            guard (SCNetworkInterfaceGetInterfaceType(interface) as String?) ==
                    (kSCNetworkInterfaceTypeEthernet as String),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                return false
            }
            return matchesTargetModem(
                usbIdentity(forBSDName: bsdName),
                locationID: locationID
            )
        }
    }

    private func completeServiceOrder(_ networkSet: SCNetworkSet) -> [String] {
        let identifiers = services(in: networkSet)
            .compactMap { SCNetworkServiceGetServiceID($0) as String? }
        let validIdentifiers = Set(identifiers)
        var order = ((SCNetworkSetGetServiceOrder(networkSet) as? [String]) ?? [])
            .filter { validIdentifiers.contains($0) }
        for identifier in identifiers where !order.contains(identifier) {
            order.append(identifier)
        }
        return order
    }

    private func relativeOrderMatches(_ current: [String], _ expected: [String]) -> Bool {
        let expectedIDs = Set(expected)
        guard current.allSatisfy(expectedIDs.contains) else { return false }
        let currentIDs = Set(current)
        return current == expected.filter { currentIDs.contains($0) }
    }

    private func systemConfigurationError(_ prefix: String) -> String {
        let code = SCError()
        guard code != kSCStatusOK else { return prefix }
        return "\(prefix)：\(String(cString: SCErrorString(code)))"
    }

    private struct DHCPFailure {
        let code: CellDockNetworkResultCode
        let message: String
    }

    private func establishDHCP(
        serviceID: String,
        interface: SCNetworkInterface,
        on bsdName: String,
        locationID: UInt32
    ) -> DHCPFailure? {
        let identity = usbIdentity(forBSDName: bsdName)
        guard let identity, matchesTargetModem(identity, locationID: locationID) else {
            return DHCPFailure(
                code: .failure,
                message: "拒绝刷新非受支持模组的网络接口 \(bsdName) 的 DHCP。"
            )
        }

        if currentLinkIsActive(on: bsdName),
           let lease = currentDHCPLease(serviceID: serviceID) {
            rootNetworkLogger.notice(
                "Existing DHCP lease is usable interface=\(bsdName, privacy: .public) address=\(lease.address, privacy: .public) router=\(lease.router, privacy: .public)"
            )
            return nil
        }

        // DHCP cannot transmit while AppleUserECM reports media inactive. Give
        // A secondary modem can need several seconds to expose carrier after
        // its bridge has been selected. Give configd an initial opportunity,
        // then restore the administrative UP flag once and wait through the
        // bridge forwarding window before deciding that recovery is required.
        if !waitForLinkActive(on: bsdName, timeout: 2.0) {
            // Bringing an interface "up" that is already administratively up
            // changes nothing. Where the policy allows it, take the interface
            // down first so the driver selects the ECM data interface again,
            // which is what makes the module announce its carrier.
            let resetsInterface = CellDockModemNetworkIdentity.resetsHostInterfaceWhenLinkIsDown(
                vendorID: identity.vendorID,
                productID: identity.productID
            )
            if resetsInterface {
                rootNetworkLogger.notice(
                    "ECM link is inactive after service enable; resetting interface interface=\(bsdName, privacy: .public)"
                )
                if let downError = runIFConfig("down", on: bsdName) {
                    rootNetworkLogger.error(
                        "Unable to take ECM interface down interface=\(bsdName, privacy: .public) error=\(downError, privacy: .public)"
                    )
                }
                Thread.sleep(forTimeInterval: 1.0)
            } else {
                rootNetworkLogger.notice(
                    "ECM link is inactive after service enable; forcing interface up interface=\(bsdName, privacy: .public)"
                )
            }
            let interfaceUpError = runIFConfig("up", on: bsdName)
            if let interfaceUpError {
                rootNetworkLogger.error(
                    "Unable to force ECM interface up interface=\(bsdName, privacy: .public) error=\(interfaceUpError, privacy: .public)"
                )
            }
            // A module rejoining its internal bridge needs roughly 26 seconds
            // (10s to raise the ECM carrier plus a ~15s bridge forwarding
            // delay), which is what the module-side recovery budgets. Waiting
            // only 18s here declared healthy-but-slow modules dead and pushed
            // them into an unnecessary power cycle.
            let activationTimeout = CellDockModemNetworkIdentity.linkActivationTimeout(
                vendorID: identity.vendorID,
                productID: identity.productID
            )
            guard waitForLinkActive(on: bsdName, timeout: activationTimeout) else {
                let suffix = interfaceUpError.map { "；ifconfig：\($0)" } ?? ""
                return DHCPFailure(
                    code: .linkInactive,
                    message: "ECM 链路在启用后仍未激活，已跳过无效 DHCP 等待\(suffix)"
                )
            }
        }

        if let lease = currentDHCPLease(serviceID: serviceID) {
            rootNetworkLogger.notice(
                "DHCP lease became usable while activating ECM interface=\(bsdName, privacy: .public) address=\(lease.address, privacy: .public) router=\(lease.router, privacy: .public)"
            )
            return nil
        }

        guard SCNetworkInterfaceForceConfigurationRefresh(interface) else {
            return DHCPFailure(
                code: .failure,
                message: systemConfigurationError("无法通知系统立即刷新 DHCP")
            )
        }
        rootNetworkLogger.info(
            "ECM link is active; waiting for system DHCP interface=\(bsdName, privacy: .public)"
        )
        if let lease = waitForDHCPLease(serviceID: serviceID, timeout: 10) {
            rootNetworkLogger.notice(
                "System DHCP succeeded interface=\(bsdName, privacy: .public) address=\(lease.address, privacy: .public) router=\(lease.router, privacy: .public)"
            )
            return nil
        }

        // Reapplying DHCP while configd has already fallen back to a
        // 169.254/16 Link-Local address is not sufficient on macOS: ipconfig
        // exits successfully, but the DHCP client can remain in INIT without
        // transmitting a new request. Wait for configd's automatic attempt
        // first, then clear the per-interface method exactly once so recovery
        // cannot repeatedly interrupt an in-flight DHCP exchange.
        rootNetworkLogger.notice(
            "System DHCP timed out; resetting the client once interface=\(bsdName, privacy: .public)"
        )
        if let error = runIPConfig(method: "NONE", on: bsdName) {
            return DHCPFailure(code: .failure, message: "重置 DHCP 客户端失败：\(error)")
        }
        Thread.sleep(forTimeInterval: 0.2)
        if let error = runIPConfig(method: "DHCP", on: bsdName) {
            return DHCPFailure(code: .failure, message: "重新启动 DHCP 客户端失败：\(error)")
        }
        guard let lease = waitForDHCPLease(serviceID: serviceID, timeout: 10) else {
            return DHCPFailure(
                code: .dhcpTimeout,
                message: "DHCP 客户端已在有效 ECM 链路上重启，但 10 秒内仍未取得 IPv4 地址和网关"
            )
        }
        rootNetworkLogger.notice(
            "DHCP reset succeeded interface=\(bsdName, privacy: .public) address=\(lease.address, privacy: .public) router=\(lease.router, privacy: .public)"
        )
        return nil
    }

    private func waitForLinkActive(on bsdName: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if currentLinkIsActive(on: bsdName) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return currentLinkIsActive(on: bsdName)
    }

    private func currentLinkIsActive(on bsdName: String) -> Bool {
        let key = "State:/Network/Interface/\(bsdName)/Link" as NSString
        guard let dictionary = SCDynamicStoreCopyValue(nil, key) as? [String: Any] else {
            return false
        }
        return dictionary["Active"] as? Bool == true
    }

    private struct DHCPLease {
        let address: String
        let router: String
    }

    private func waitForDHCPLease(serviceID: String, timeout: TimeInterval) -> DHCPLease? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let lease = currentDHCPLease(serviceID: serviceID) {
                return lease
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return currentDHCPLease(serviceID: serviceID)
    }

    private func currentDHCPLease(serviceID: String) -> DHCPLease? {
        let key = "State:/Network/Service/\(serviceID)/IPv4" as NSString
        guard let dictionary = SCDynamicStoreCopyValue(nil, key) as? [String: Any],
              let address = (dictionary["Addresses"] as? [String])?.first(where: isUsableIPv4),
              let router = dictionary["Router"] as? String,
              isUsableIPv4(router) else {
            return nil
        }
        return DHCPLease(address: address, router: router)
    }

    private func isUsableIPv4(_ address: String) -> Bool {
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let octets = components.compactMap { component -> Int? in
            guard !component.isEmpty,
                  component.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let value = Int(component),
                  (0 ... 255).contains(value) else {
                return nil
            }
            return value
        }
        guard octets.count == 4 else { return false }
        if octets[0] == 0 || octets[0] == 127 || octets[0] >= 224 { return false }
        return !(octets[0] == 169 && octets[1] == 254)
    }

    private func runIPConfig(method: String, on bsdName: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        process.arguments = ["set", bsdName, method]
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return detail?.isEmpty == false
                ? detail
                : "ipconfig \(method) 返回状态 \(process.terminationStatus)"
        }
        return nil
    }

    private func runIFConfig(_ action: String, on bsdName: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [bsdName, action]
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return detail?.isEmpty == false
                ? detail
                : "ifconfig \(action) 返回状态 \(process.terminationStatus)"
        }
        return nil
    }

    private struct USBIdentity: Equatable {
        let vendorID: Int
        let productID: Int
        let locationID: UInt32?
    }

    /// Matches the vendor name that SCPreferences keeps for a modem interface.
    /// This is the only identifier that survives once the hardware is detached.
    private func isKnownModemInterfaceName(_ value: String?) -> Bool {
        CellDockModemNetworkIdentity.isKnownInterfaceName(value)
    }

    private func serviceName(for interface: SCNetworkInterface, locationID: UInt32) -> String {
        let identity = (SCNetworkInterfaceGetBSDName(interface) as String?)
            .flatMap(usbIdentity(forBSDName:))
        return CellDockModemNetworkIdentity.serviceName(
            vendorID: identity?.vendorID ?? 0,
            productID: identity?.productID ?? 0,
            locationID: locationID
        )
    }

    private func matchesTargetModem(
        _ identity: USBIdentity?,
        locationID: UInt32
    ) -> Bool {
        guard let identity,
              CellDockModemNetworkIdentity.isSupported(
                  vendorID: identity.vendorID,
                  productID: identity.productID
              ) else {
            return false
        }
        return locationID == 0 || identity.locationID == locationID
    }

    private func usbIdentity(forBSDName bsdName: String) -> USBIdentity? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let networkInterface = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard networkInterface != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(networkInterface) }

        let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        func integerProperty(_ key: String) -> Int? {
            (IORegistryEntrySearchCFProperty(
                networkInterface,
                kIOServicePlane,
                key as CFString,
                kCFAllocatorDefault,
                options
            ) as? NSNumber)?.intValue
        }

        guard let vendorID = integerProperty(kUSBVendorID),
              let productID = integerProperty(kUSBProductID) else {
            return nil
        }
        return USBIdentity(
            vendorID: vendorID,
            productID: productID,
            locationID: integerProperty("locationID").map(UInt32.init)
        )
    }
}
