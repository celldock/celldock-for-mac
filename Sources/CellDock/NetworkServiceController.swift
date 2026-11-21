import Foundation
import IOKit
import IOKit.network
import IOKit.usb
import CellDockNetworkIPC
import OSLog
import SystemConfiguration

private let cellularNetworkLogger = Logger(
    subsystem: "app.celldock.mac",
    category: "CellularNetwork"
)

final class NetworkServiceController {
    var onStatus: ((CellularNetworkStatus) -> Void)?
    var onStatuses: (([UInt32: CellularNetworkStatus]) -> Void)?

    private let queue = DispatchQueue(label: "app.celldock.mac.network", qos: .userInitiated)
    private let helperClient = NetworkHelperClient()
    private var timer: DispatchSourceTimer?
    private var lastPublishedStatus: CellularNetworkStatus?
    private var lastPublishedStatuses: [UInt32: CellularNetworkStatus] = [:]
    private var reportedAddressOverlapLocationIDs: Set<UInt32> = []
    private var preferredLocationID: UInt32?
    private let serviceRecordKey = "CellDock.modemNetworkServiceRecord"

    func startMonitoring() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(750))
            timer.setEventHandler { [weak self] in self?.refreshNow() }
            self.timer = timer
            timer.resume()
        }
    }

    func stopMonitoring() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.refreshNow() }
    }

    func setPreferredLocationID(_ locationID: UInt32?) {
        queue.async { [weak self] in
            guard let self, self.preferredLocationID != locationID else { return }
            self.preferredLocationID = locationID
            self.lastPublishedStatus = nil
            self.refreshNow()
        }
    }

    func applyConfiguration(
        _ request: CellularNetworkConfigurationRequest,
        completion: @escaping (CellularNetworkActionResult) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            if !request.enabledLocationIDs.isEmpty &&
                request.enabledLocationIDs.contains(where: {
                    self.findLiveModemInterface(locationID: $0) == nil
                }) {
                DispatchQueue.main.async {
                    completion(.failure(
                        L10n.tr("没有找到实时 QDC507 CDC-ECM 接口；未安装 helper，也未修改网络配置。"),
                        reason: .other
                    ))
                }
                return
            }
            self.helperClient.applyCellularNetworkConfiguration(request) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    self.refreshNow()
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }

    private func refreshNow() {
        let status = readStatus()
        let statuses = readAllStatuses()
        let statusChanged = lastPublishedStatus != status
        let statusesChanged = lastPublishedStatuses != statuses
        guard statusChanged || statusesChanged else { return }
        if statusChanged { lastPublishedStatus = status }
        if statusesChanged { lastPublishedStatuses = statuses }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if statusChanged { self.onStatus?(status) }
            if statusesChanged { self.onStatuses?(statuses) }
        }
    }

    private func readAllStatuses() -> [UInt32: CellularNetworkStatus] {
        guard let preferences = SCPreferencesCreate(nil, "CellDock All Modules" as NSString, nil),
              let networkSet = SCNetworkSetCopyCurrent(preferences) else {
            return [:]
        }
        let order = completeServiceOrder(networkSet)
        let servicesByIdentifier = servicesByID(in: networkSet)
        let primaryServiceID = (
            SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as NSString)
                as? [String: Any]
        )?["PrimaryService"] as? String
        var result: [UInt32: CellularNetworkStatus] = [:]

        for service in services(in: networkSet) {
            guard let interface = SCNetworkServiceGetInterface(service),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let identity = usbIdentity(forBSDName: bsdName),
                  matchesTargetModem(identity),
                  let locationID = identity.locationID,
                  let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
                continue
            }
            let targetIndex = order.firstIndex(of: serviceID)
            let higherPriorityService = targetIndex.flatMap { index in
                order[..<index]
                    .compactMap { servicesByIdentifier[$0] }
                    .first(where: SCNetworkServiceGetEnabled)
            }
            let isPrioritized = targetIndex.map { index in
                !order[..<index]
                    .compactMap { servicesByIdentifier[$0] }
                    .contains(where: SCNetworkServiceGetEnabled)
            } ?? false
            let isDemoted = targetIndex.map { index in
                order.enumerated().allSatisfy { candidateIndex, identifier in
                    guard identifier != serviceID,
                          let candidate = servicesByIdentifier[identifier],
                          !isTargetModemService(candidate) else { return true }
                    return candidateIndex < index
                }
            } ?? false
            let ipv4State = activeIPv4State(serviceID: serviceID, bsdName: bsdName)
            let dnsServers = activeDNSServers(serviceID: serviceID)
            let activeIPv6 = activeGlobalIPv6Address(forBSDName: bsdName)
            let linkActive = activeLinkStatus(forBSDName: bsdName) ??
                (ipv4State.address != nil || activeIPv6 != nil)
            result[locationID] = CellularNetworkStatus(
                serviceID: serviceID,
                serviceName: SCNetworkServiceGetName(service) as String?,
                higherPriorityServiceName: higherPriorityService.map(userFacingServiceName),
                bsdName: bsdName,
                isEnabled: SCNetworkServiceGetEnabled(service),
                isActive: linkActive && (
                    (ipv4State.address != nil && ipv4State.router != nil) || activeIPv6 != nil
                ),
                isLinkActive: linkActive,
                isPrioritized: isPrioritized,
                isDemoted: isDemoted,
                isSystemPrimary: primaryServiceID == serviceID,
                isHardwarePresent: true,
                ipv4Address: ipv4State.address,
                ipv4Router: ipv4State.router,
                ipv6Address: activeIPv6,
                dnsServers: dnsServers
            )
        }

        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let identity = usbIdentity(forBSDName: bsdName),
                  matchesTargetModem(identity),
                  let locationID = identity.locationID,
                  result[locationID] == nil else { continue }
            result[locationID] = CellularNetworkStatus(
                bsdName: bsdName,
                isHardwarePresent: true
            )
        }

        let issues = CellularNetworkConflictPolicy.issues(forStatusesByLocationID: result)
        for (locationID, issue) in issues {
            result[locationID]?.issue = issue
            guard let status = result[locationID] else { continue }
            logAddressOverlap(locationID: locationID, issue: issue, status: status)
        }
        reportedAddressOverlapLocationIDs.formIntersection(Set(issues.keys))
        return result
    }

    private func logAddressOverlap(
        locationID: UInt32,
        issue: CellularNetworkIssue,
        status: CellularNetworkStatus
    ) {
        guard reportedAddressOverlapLocationIDs.insert(locationID).inserted else { return }
        let summary = """
            location=0x\(String(locationID, radix: 16)) \
            interface=\(status.bsdName ?? "unknown") \
            address=\(status.ipv4Address ?? "none") \
            router=\(status.ipv4Router ?? "none") \
            service=\(status.serviceID ?? "none")
            """
        switch issue {
        case .duplicateAddress:
            cellularNetworkLogger.error(
                "Cellular duplicate address \(summary, privacy: .public)"
            )
        case .sharedSubnet:
            // Expected for any multi-module setup because the modem firmware
            // pins its ECM gateway, so this is a diagnostic breadcrumb only.
            cellularNetworkLogger.info(
                "Cellular shared subnet \(summary, privacy: .public)"
            )
        }
    }

    private func readStatus() -> CellularNetworkStatus {
        guard let preferences = SCPreferencesCreate(nil, "CellDock" as NSString, nil),
              let networkSet = SCNetworkSetCopyCurrent(preferences) else {
            return CellularNetworkStatus(
                lastError: systemConfigurationError(L10n.tr("无法读取网络配置"))
            )
        }
        let liveInterface = findLiveModemInterface()
        let liveService = findLiveModemService(in: networkSet)
        let service = liveService ?? recordedService(in: networkSet) ?? namedDisplayService(in: networkSet)
        guard let service else {
            return CellularNetworkStatus(
                bsdName: liveInterface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? },
                isHardwarePresent: liveInterface != nil
            )
        }

        let serviceID = SCNetworkServiceGetServiceID(service) as String?
        let serviceName = SCNetworkServiceGetName(service) as String?
        let interface = SCNetworkServiceGetInterface(service)
        let bsdName = interface.flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
        let order = completeServiceOrder(networkSet)
        let orderedServices = servicesByID(in: networkSet)
        let higherPriorityService = serviceID.flatMap { targetID -> SCNetworkService? in
            guard let targetIndex = order.firstIndex(of: targetID) else { return nil }
            return order[..<targetIndex]
                .compactMap { orderedServices[$0] }
                .first(where: SCNetworkServiceGetEnabled)
        }
        let isPrioritized = serviceID.map { targetID in
            guard let targetIndex = order.firstIndex(of: targetID) else { return false }
            return !order[..<targetIndex]
                .compactMap { orderedServices[$0] }
                .contains(where: SCNetworkServiceGetEnabled)
        } ?? false
        let isDemoted = serviceID.map { targetID in
            guard let targetIndex = order.firstIndex(of: targetID) else { return false }
            return order.enumerated().allSatisfy { index, identifier in
                guard identifier != targetID,
                      let candidate = orderedServices[identifier],
                      !isTargetModemService(candidate) else {
                    return true
                }
                return index < targetIndex
            }
        } ?? false
        let ipv4State = activeIPv4State(serviceID: serviceID, bsdName: bsdName)
        let activeIPv4 = ipv4State.address
        let activeIPv4Router = ipv4State.router
        let dnsServers = activeDNSServers(serviceID: serviceID)
        let activeIPv6 = bsdName.flatMap(activeGlobalIPv6Address)
        let linkActive = bsdName.flatMap(activeLinkStatus) ??
            (activeIPv4 != nil || activeIPv6 != nil)
        if liveService != nil,
           let serviceID,
           let bsdName,
           let setID = SCNetworkSetGetSetID(networkSet) as String? {
            saveServiceRecord(ServiceRecord(setID: setID, serviceID: serviceID, bsdName: bsdName))
        }

        return CellularNetworkStatus(
            serviceID: serviceID,
            serviceName: serviceName,
            higherPriorityServiceName: higherPriorityService.map(userFacingServiceName),
            bsdName: bsdName,
            isEnabled: SCNetworkServiceGetEnabled(service),
            isActive: linkActive && (
                (activeIPv4 != nil && activeIPv4Router != nil) || activeIPv6 != nil
            ),
            isLinkActive: linkActive,
            isPrioritized: isPrioritized,
            isDemoted: isDemoted,
            isHardwarePresent: liveInterface != nil,
            ipv4Address: activeIPv4,
            ipv4Router: activeIPv4Router,
            ipv6Address: activeIPv6,
            dnsServers: dnsServers,
            lastError: nil
        )
    }

    private func services(in networkSet: SCNetworkSet) -> [SCNetworkService] {
        guard let rawServices = SCNetworkSetCopyServices(networkSet) else { return [] }
        return (rawServices as? [SCNetworkService]) ?? []
    }

    private func servicesByID(in networkSet: SCNetworkSet) -> [String: SCNetworkService] {
        Dictionary(uniqueKeysWithValues: services(in: networkSet).compactMap { service in
            guard let identifier = SCNetworkServiceGetServiceID(service) as String? else {
                return nil
            }
            return (identifier, service)
        })
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

    private func userFacingServiceName(_ service: SCNetworkService) -> String {
        let rawName = (SCNetworkServiceGetName(service) as String?) ?? ""
        let normalized = rawName.lowercased()
        if normalized.contains("wi-fi") || normalized.contains("wifi") ||
            normalized.contains("无线局域网") {
            return "Wi‑Fi"
        }
        if let interface = SCNetworkServiceGetInterface(service),
           (SCNetworkInterfaceGetInterfaceType(interface) as String?) ==
            (kSCNetworkInterfaceTypeEthernet as String) {
            return L10n.tr("以太网")
        }
        return rawName.isEmpty ? L10n.tr("其他网络") : rawName
    }

    private func findLiveModemService(in networkSet: SCNetworkSet) -> SCNetworkService? {
        services(in: networkSet).first { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  (SCNetworkInterfaceGetInterfaceType(interface) as String?) == (kSCNetworkInterfaceTypeEthernet as String),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                return false
            }
            return matchesPreferredModem(usbIdentity(forBSDName: bsdName))
        }
    }

    private func recordedService(in networkSet: SCNetworkSet) -> SCNetworkService? {
        guard let record = loadServiceRecord(),
              (SCNetworkSetGetSetID(networkSet) as String?) == record.setID else {
            return nil
        }
        return services(in: networkSet).first {
            (SCNetworkServiceGetServiceID($0) as String?) == record.serviceID &&
                (SCNetworkServiceGetInterface($0).flatMap { SCNetworkInterfaceGetBSDName($0) as String? }) == record.bsdName &&
                matchesPreferredModem(usbIdentity(forBSDName: record.bsdName))
        }
    }

    private func namedDisplayService(in networkSet: SCNetworkSet) -> SCNetworkService? {
        services(in: networkSet).first { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  (SCNetworkInterfaceGetInterfaceType(interface) as String?) == (kSCNetworkInterfaceTypeEthernet as String) else {
                return false
            }
            let serviceName = (SCNetworkServiceGetName(service) as String?) ?? ""
            let interfaceName = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? ""
            guard isKnownModemName(serviceName) || isKnownModemName(interfaceName),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
                return false
            }
            return matchesPreferredModem(usbIdentity(forBSDName: bsdName))
        }
    }

    private func findLiveModemInterface() -> SCNetworkInterface? {
        findLiveModemInterface(locationID: preferredLocationID)
    }

    private func findLiveModemInterface(locationID: UInt32?) -> SCNetworkInterface? {
        let rawInterfaces = SCNetworkInterfaceCopyAll()
        let interfaces = (rawInterfaces as? [SCNetworkInterface]) ?? []
        return interfaces.first { interface in
            guard (SCNetworkInterfaceGetInterfaceType(interface) as String?) == (kSCNetworkInterfaceTypeEthernet as String),
                  let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { return false }
            guard let identity = usbIdentity(forBSDName: bsdName),
                  matchesTargetModem(identity) else { return false }
            return locationID == nil || identity.locationID == locationID
        }
    }

    private func isKnownModemName(_ value: String) -> Bool {
        CellDockModemNetworkIdentity.isKnownInterfaceName(value)
    }

    private struct IPv4State {
        let address: String?
        let router: String?
    }

    private func activeIPv4State(serviceID: String?, bsdName: String?) -> IPv4State {
        var serviceDictionary: [String: Any]?
        if let serviceID {
            let key = "State:/Network/Service/\(serviceID)/IPv4" as NSString
            serviceDictionary = SCDynamicStoreCopyValue(nil, key) as? [String: Any]
        }
        let serviceAddress = (serviceDictionary?["Addresses"] as? [String])?
            .first(where: NetworkAddressClassifier.isUsableIPv4)
        let router = (serviceDictionary?["Router"] as? String).flatMap {
            NetworkAddressClassifier.isUsableIPv4($0) ? $0 : nil
        }
        if serviceAddress != nil || router != nil {
            return IPv4State(address: serviceAddress, router: router)
        }

        guard let bsdName else { return IPv4State(address: nil, router: nil) }
        let key = "State:/Network/Interface/\(bsdName)/IPv4" as NSString
        let dictionary = SCDynamicStoreCopyValue(nil, key) as? [String: Any]
        let interfaceAddress = (dictionary?["Addresses"] as? [String])?
            .first(where: NetworkAddressClassifier.isUsableIPv4)
        return IPv4State(address: interfaceAddress, router: nil)
    }

    private func activeDNSServers(serviceID: String?) -> [String] {
        guard let serviceID else { return [] }
        let key = "State:/Network/Service/\(serviceID)/DNS" as NSString
        let dictionary = SCDynamicStoreCopyValue(nil, key) as? [String: Any]
        return CellularDNSStateParser.serverAddresses(from: dictionary)
    }

    private func activeGlobalIPv6Address(forBSDName bsdName: String) -> String? {
        let key = "State:/Network/Interface/\(bsdName)/IPv6" as NSString
        guard let value = SCDynamicStoreCopyValue(nil, key),
              let dictionary = value as? [String: Any],
              let addresses = dictionary["Addresses"] as? [String] else {
            return nil
        }
        return addresses.first { address in
            let normalized = address.lowercased()
            return normalized != "::1" && !normalized.hasPrefix("fe80:")
        }
    }

    private func activeLinkStatus(forBSDName bsdName: String) -> Bool? {
        let key = "State:/Network/Interface/\(bsdName)/Link" as NSString
        guard let value = SCDynamicStoreCopyValue(nil, key),
              let dictionary = value as? [String: Any] else {
            return nil
        }
        return dictionary["Active"] as? Bool
    }

    private func systemConfigurationError(_ prefix: String) -> String {
        let code = SCError()
        guard code != kSCStatusOK else { return prefix }
        return L10n.tr("%@：%@", prefix, String(cString: SCErrorString(code)))
    }

    private struct ServiceRecord: Codable {
        let setID: String
        let serviceID: String
        let bsdName: String
    }

    private func saveServiceRecord(_ record: ServiceRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: serviceRecordKey)
    }

    private func loadServiceRecord() -> ServiceRecord? {
        guard let data = UserDefaults.standard.data(forKey: serviceRecordKey) else { return nil }
        return try? JSONDecoder().decode(ServiceRecord.self, from: data)
    }

    private struct USBIdentity: Equatable {
        let vendorID: Int
        let productID: Int
        let locationID: UInt32?
    }

    private func matchesPreferredModem(_ identity: USBIdentity?) -> Bool {
        guard let identity, matchesTargetModem(identity) else {
            return false
        }
        guard let preferredLocationID else { return true }
        return identity.locationID == preferredLocationID
    }

    private func isTargetModemService(_ service: SCNetworkService) -> Bool {
        guard let interface = SCNetworkServiceGetInterface(service),
              let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else {
            return false
        }
        return usbIdentity(forBSDName: bsdName).map(matchesTargetModem) ?? false
    }

    private func matchesTargetModem(_ identity: USBIdentity) -> Bool {
        CellDockModemNetworkIdentity.isSupported(
            vendorID: identity.vendorID,
            productID: identity.productID
        )
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
        let locationID = integerProperty("locationID").map(UInt32.init)
        return USBIdentity(
            vendorID: vendorID,
            productID: productID,
            locationID: locationID
        )
    }
}
