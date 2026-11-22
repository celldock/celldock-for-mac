import Combine
import Foundation
import SwiftUI

/// Per-module network speed, read once a second from each module's ECM
/// interface counters. It runs only while some view that shows the numbers is
/// on screen: views subscribe on appear and unsubscribe on disappear, and the
/// timer stops when the last one goes away.
@MainActor
final class ModuleThroughputMonitor: ObservableObject {
    /// Last 60 samples per module, oldest first.
    @Published private(set) var histories: [CellularModuleID: NetworkThroughputHistory] = [:]

    private unowned let appState: AppState
    private var subscriberCount = 0
    private var timer: Timer?
    private var baselines: [CellularModuleID: (bsdName: String, counters: NetworkInterfaceByteCounters)] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    var isSampling: Bool { timer != nil }

    func subscribe() {
        subscriberCount += 1
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func unsubscribe() {
        subscriberCount = max(0, subscriberCount - 1)
        guard subscriberCount == 0 else { return }
        timer?.invalidate()
        timer = nil
        baselines.removeAll()
        histories.removeAll()
    }

    /// Latest speed, or nil when the module is not being measured (offline,
    /// no interface yet, or before the second sample).
    func current(for moduleID: CellularModuleID) -> NetworkThroughput? {
        histories[moduleID]?.latest
    }

    func history(for moduleID: CellularModuleID) -> NetworkThroughputHistory {
        histories[moduleID] ?? NetworkThroughputHistory()
    }

    private func sample() {
        var interfaces: [CellularModuleID: String] = [:]
        for module in appState.cellularModules {
            // Only modules whose ECM link is up; the others show their state.
            if let name = module.network.bsdName, !name.isEmpty,
               module.network.isHardwarePresent, module.network.isLinkActive {
                interfaces[module.id] = name
            }
        }
        var updated = histories
        for id in updated.keys where interfaces[id] == nil {
            updated[id] = nil
            baselines[id] = nil
        }
        for (id, bsdName) in interfaces {
            guard let counters = NetworkInterfaceCounterReader.read(interfaceName: bsdName) else {
                // The interface went away; start over once it is back.
                baselines[id] = nil
                updated[id] = nil
                continue
            }
            if let baseline = baselines[id], baseline.bsdName == bsdName {
                var history = updated[id] ?? NetworkThroughputHistory()
                // A counter reset (module re-enumerated) yields nil; show zero
                // for that second rather than a false spike.
                history.append(
                    NetworkThroughputCalculator.rates(previous: baseline.counters, current: counters) ?? .zero
                )
                updated[id] = history
            } else {
                // New module or a different interface name: new baseline.
                updated[id] = NetworkThroughputHistory()
            }
            baselines[id] = (bsdName, counters)
        }
        if updated != histories {
            histories = updated
        }
    }
}

private struct ModuleThroughputSubscriptionModifier: ViewModifier {
    let monitor: ModuleThroughputMonitor

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.subscribe() }
            .onDisappear { monitor.unsubscribe() }
    }
}

extension View {
    /// Keeps per-module speed sampling running while this view is visible.
    func sampleModuleThroughput(_ monitor: ModuleThroughputMonitor) -> some View {
        modifier(ModuleThroughputSubscriptionModifier(monitor: monitor))
    }
}

/// "↓2.4M ↑320K" for one module, observing only the monitor so that the
/// surrounding list does not redraw every second.
struct ModuleThroughputText: View {
    @ObservedObject var monitor: ModuleThroughputMonitor
    let moduleID: CellularModuleID
    /// Shown instead of the speed when there is nothing to measure.
    var unavailableText: String?
    var style: Style = .compact
    /// Put before the speed only, e.g. " · " after other details.
    var prefix: String = ""

    enum Style {
        /// "↓2.4M ↑320K"
        case compact
        /// "↓ 2.4M/s ↑ 320K/s"
        case perSecond
    }

    var body: some View {
        if let throughput = monitor.current(for: moduleID) {
            Text(verbatim: prefix + text(throughput))
                .monospacedDigit()
                .accessibilityLabel(NetworkSpeedFormatter.detailedText(throughput))
        } else if let unavailableText {
            Text(verbatim: unavailableText)
        }
    }

    private func text(_ throughput: NetworkThroughput) -> String {
        switch style {
        case .compact:
            return NetworkSpeedFormatter.compactPair(throughput)
        case .perSecond:
            let lines = NetworkSpeedFormatter.menuBarLines(throughput)
            return lines.download + " " + lines.upload
        }
    }
}
