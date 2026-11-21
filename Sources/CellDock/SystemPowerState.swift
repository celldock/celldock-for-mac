import Foundation
import IOKit

/// Whether the Mac is fully awake or only in a dark wake.
///
/// A sleeping Mac wakes briefly every few minutes for maintenance (Power Nap).
/// Apps keep running during those dark wakes, so link recovery would run too:
/// with a module whose link cannot be repaired that meant restarting the
/// module again and again all night. Recovery is therefore limited to a full
/// wake, where somebody can actually use the connection.
enum SystemPowerState {
    /// `kIOPMSystemCapabilityGraphics` from IOKit/pwr_mgt/IOPM.h. The power
    /// root domain sets it for a full wake and clears it for a dark wake; it
    /// stays set while only the display is asleep.
    private static let graphicsCapability = 0x02

    /// Pure interpretation of the root domain's "System Capabilities" value.
    /// An unreadable value counts as awake, so a missing property can never
    /// switch recovery off for good.
    static func isFullWake(capabilities: Int?) -> Bool {
        guard let capabilities else { return true }
        return capabilities & graphicsCapability != 0
    }

    static func isFullyAwake() -> Bool {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard rootDomain != IO_OBJECT_NULL else { return true }
        defer { IOObjectRelease(rootDomain) }
        let value = IORegistryEntryCreateCFProperty(
            rootDomain,
            "System Capabilities" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber
        return isFullWake(capabilities: value?.intValue)
    }
}
