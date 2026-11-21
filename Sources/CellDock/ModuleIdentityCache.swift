import Foundation

/// Remembers which IMEI sits behind each attached USB module while its AT
/// session is down.
///
/// A SOCKS proxy is bound to a module by IMEI, and the IMEI is only readable
/// over AT. The proxy's data path is the module's ECM interface, which keeps
/// working when the AT session has to reconnect: after a slow command, an SMS
/// that waited on the network, or a re-initialization. Without this cache each
/// of those made the proxy lose its module, stop listening and drop every live
/// connection although nothing was wrong with the link.
///
/// An entry lives exactly as long as the same physical enumeration of the
/// device: unplugging, swapping or restarting the module changes its registry
/// ID, so a different module on the same port can never inherit an IMEI.
struct ModuleIdentityCache: Equatable {
    struct Device: Equatable {
        let locationID: UInt32
        let registryID: UInt64
    }

    private struct Entry: Equatable {
        let registryID: UInt64
        let imei: String
    }

    private var entries: [UInt32: Entry] = [:]

    /// Records an IMEI read over AT. `device` is the inventory record for the
    /// USB location the IMEI was read from; without one the module is not
    /// known to be attached and nothing is remembered.
    mutating func record(imei: String?, device: Device?) {
        guard let imei, !imei.isEmpty, let device else { return }
        entries[device.locationID] = Entry(registryID: device.registryID, imei: imei)
    }

    /// Drops every entry whose device is gone or has been enumerated again.
    mutating func retain(devices: [Device]) {
        var present: [UInt32: UInt64] = [:]
        for device in devices { present[device.locationID] = device.registryID }
        entries = entries.filter { present[$0.key] == $0.value.registryID }
    }

    func imei(forLocationID locationID: UInt32) -> String? {
        entries[locationID]?.imei
    }

    func locationID(forIMEI imei: String) -> UInt32? {
        entries.first { $0.value.imei == imei }?.key
    }
}
