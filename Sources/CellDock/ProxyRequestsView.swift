import AppKit
import Charts
import SwiftUI

enum ProxyDetailTab: String {
    case settings
    case requests
}

enum ProxyThroughputScope: String {
    case module
    case proxy
}

/// The "请求" tab of a proxy: live speed, running requests and the in-memory
/// history of finished ones.
struct ProxyRequestsView: View {
    @StateObject private var feed: SOCKSProxyRequestFeed
    @ObservedObject var controller: SOCKSProxyController
    @ObservedObject var monitor: ModuleThroughputMonitor
    let moduleTitle: String
    let interfaceName: String?

    @AppStorage("ProxyThroughputScope.v1") private var storedScope = ProxyThroughputScope.module.rawValue
    @State private var listKind: ListKind = .active
    @State private var failuresOnly = false
    @State private var query = ""
    @State private var selection: UUID?
    @State private var isConfirmingClear = false

    enum ListKind: Hashable {
        case active
        case history
    }

    init(
        proxyID: UUID,
        controller: SOCKSProxyController,
        monitor: ModuleThroughputMonitor,
        moduleTitle: String,
        interfaceName: String?
    ) {
        _feed = StateObject(wrappedValue: SOCKSProxyRequestFeed(proxyID: proxyID, controller: controller))
        self.controller = controller
        self.monitor = monitor
        self.moduleTitle = moduleTitle
        self.interfaceName = interfaceName
    }

    var body: some View {
        AdaptiveGlassContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ProxyThroughputCard(
                    feed: feed,
                    monitor: monitor,
                    scope: scope,
                    egressModuleID: controller.egressModuleID(for: feed.proxyID),
                    moduleTitle: moduleTitle,
                    interfaceName: interfaceName
                )
                toolbar
                HStack(alignment: .top, spacing: 14) {
                    requestTable
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let record = selectedRecord {
                        ProxyRequestDetailPanel(
                            record: record,
                            now: feed.now,
                            egress: egressDescription,
                            onClose: { selection = nil },
                            onDisconnect: { feed.cancel(record.id) }
                        )
                        .frame(width: 290)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)
                footer
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.2), value: selection)
        .onAppear {
            feed.start()
            monitor.subscribe()
        }
        .onDisappear {
            feed.stop()
            monitor.unsubscribe()
        }
        .onChange(of: listKind) { _, _ in selection = nil }
        .confirmationDialog(
            L10n.tr("清除这个代理的请求历史？"),
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("清除历史"), role: .destructive) {
                if let selection, feed.snapshot.history.contains(where: { $0.id == selection }) {
                    self.selection = nil
                }
                feed.clearHistory()
            }
            Button(L10n.tr("取消"), role: .cancel) {}
        }
    }

    private var scope: Binding<ProxyThroughputScope> {
        Binding(
            get: { ProxyThroughputScope(rawValue: storedScope) ?? .module },
            set: { storedScope = $0.rawValue }
        )
    }

    private var egressDescription: String {
        [moduleTitle, interfaceName].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker(L10n.tr("请求类型"), selection: $listKind) {
                Text(verbatim: L10n.tr("活动中 %lld", Int64(feed.snapshot.active.count)))
                    .tag(ListKind.active)
                Text(verbatim: L10n.tr("历史 %lld", Int64(feed.snapshot.history.count)))
                    .tag(ListKind.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if listKind == .history {
                Picker(L10n.tr("结果筛选"), selection: $failuresOnly) {
                    Text(verbatim: L10n.tr("全部")).tag(false)
                    Text(verbatim: L10n.tr("仅失败 %lld", Int64(failureCount))).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Spacer(minLength: 8)

            TextField(
                L10n.tr("搜索目标或客户端"),
                text: $query,
                prompt: Text(verbatim: L10n.tr("搜索域名、IP 或客户端"))
            )
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .frame(width: 220)

            if listKind == .history {
                Button(L10n.tr("清除历史")) { isConfirmingClear = true }
                    .adaptiveGlassButton(.regular)
                    .disabled(feed.snapshot.history.isEmpty)
            }
        }
        .controlSize(.regular)
    }

    private var failureCount: Int {
        feed.snapshot.history.reduce(0) { $0 + ($1.outcome.isFailure ? 1 : 0) }
    }

    // MARK: Table

    private var activeRows: [SOCKSProxyRequestRecord] {
        feed.snapshot.active.filter { $0.matches(query: query) }
    }

    private var historyRows: [SOCKSProxyRequestRecord] {
        feed.snapshot.history.filter {
            $0.matches(query: query) && (!failuresOnly || $0.outcome.isFailure)
        }
    }

    private var selectedRecord: SOCKSProxyRequestRecord? {
        guard let selection else { return nil }
        return feed.snapshot.active.first(where: { $0.id == selection })
            ?? feed.snapshot.history.first(where: { $0.id == selection })
    }

    @ViewBuilder private var requestTable: some View {
        Group {
            switch listKind {
            case .active:
                Table(activeRows, selection: $selection) {
                    TableColumn(L10n.tr("目标")) { record in
                        ProxyRequestTargetCell(record: record)
                    }
                    .width(min: 160, ideal: 260)
                    TableColumn(L10n.tr("客户端")) { record in
                        monoText(record.client)
                    }
                    .width(min: 90, ideal: 140)
                    TableColumn(L10n.tr("时长")) { record in
                        monoText(ProxyRequestPresentation.duration(record.duration(now: feed.now)))
                    }
                    .width(min: 60, ideal: 84)
                    TableColumn(L10n.tr("下载")) { record in
                        monoText(NetworkSpeedFormatter.byteCount(record.downloadedBytes))
                    }
                    .width(min: 60, ideal: 80)
                    TableColumn(L10n.tr("上传")) { record in
                        monoText(NetworkSpeedFormatter.byteCount(record.uploadedBytes))
                    }
                    .width(min: 60, ideal: 80)
                }
            case .history:
                Table(historyRows, selection: $selection) {
                    TableColumn(L10n.tr("时间")) { record in
                        monoText(ProxyRequestPresentation.time(record.endedAt ?? record.startedAt))
                    }
                    .width(min: 64, ideal: 72)
                    TableColumn(L10n.tr("目标")) { record in
                        ProxyRequestTargetCell(record: record)
                    }
                    .width(min: 160, ideal: 240)
                    TableColumn(L10n.tr("客户端")) { record in
                        monoText(record.client)
                    }
                    .width(min: 90, ideal: 130)
                    TableColumn(L10n.tr("结果")) { record in
                        ProxyRequestOutcomeBadge(outcome: record.outcome)
                    }
                    .width(min: 70, ideal: 96)
                    TableColumn(L10n.tr("时长")) { record in
                        monoText(ProxyRequestPresentation.duration(record.duration()))
                    }
                    .width(min: 56, ideal: 76)
                    TableColumn(L10n.tr("流量")) { record in
                        monoText(NetworkSpeedFormatter.byteCount(record.totalBytes))
                    }
                    .width(min: 60, ideal: 80)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .overlay { emptyState }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 6, treatment: .regular)
    }

    @ViewBuilder private var emptyState: some View {
        let isEmpty = listKind == .active ? activeRows.isEmpty : historyRows.isEmpty
        if isEmpty {
            VStack(spacing: 6) {
                Image(systemName: listKind == .active ? "arrow.left.arrow.right" : "clock.arrow.circlepath")
                    .font(.appSymbol(.button))
                    .foregroundStyle(.tertiary)
                Text(verbatim: emptyText)
                    .font(.appCallout)
                    .foregroundStyle(.secondary)
                if listKind == .history && !controller.recordsRequestHistory {
                    Text(verbatim: L10n.tr("记录历史已关闭"))
                        .font(.appCaption)
                        .foregroundStyle(.tertiary)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var emptyText: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return L10n.tr("没有匹配的请求")
        }
        switch listKind {
        case .active: return L10n.tr("没有活动中的请求")
        case .history: return failuresOnly ? L10n.tr("没有失败的请求") : L10n.tr("没有记录")
        }
    }

    private func monoText(_ value: String) -> some View {
        Text(verbatim: value)
            .font(.appCallout.monospacedDigit())
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.appCaption)
                .foregroundStyle(.secondary)
            Text(verbatim: L10n.tr("历史只保存在内存里，最多 1,000 条，退出 CellDock 后清空"))
                .font(.appCaption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 12)
            // Native switch: Liquid Glass on macOS 26+, a regular switch before.
            Toggle(L10n.tr("记录历史"), isOn: $controller.recordsRequestHistory)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Live speed card

private struct ProxyThroughputCard: View {
    @ObservedObject var feed: SOCKSProxyRequestFeed
    @ObservedObject var monitor: ModuleThroughputMonitor
    @Binding var scope: ProxyThroughputScope
    let egressModuleID: CellularModuleID?
    let moduleTitle: String
    let interfaceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(verbatim: L10n.tr("实时网速")).font(.appBodyStrong)
                Spacer(minLength: 12)
                Picker(L10n.tr("统计范围"), selection: $scope) {
                    Text(verbatim: L10n.tr("出口模组")).tag(ProxyThroughputScope.module)
                    Text(verbatim: L10n.tr("仅本代理")).tag(ProxyThroughputScope.proxy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            HStack(alignment: .center, spacing: 22) {
                speedValue(
                    title: L10n.tr("下载"),
                    color: .blue,
                    value: current?.downloadBytesPerSecond
                )
                speedValue(
                    title: L10n.tr("上传"),
                    color: .orange,
                    value: current?.uploadBytesPerSecond
                )
                ProxyThroughputChart(history: history)
                    .frame(maxWidth: .infinity)
                    .frame(height: 76)
            }

            HStack(spacing: 14) {
                Text(verbatim: L10n.tr("最近 60 秒"))
                Text(verbatim: note)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if scope == .proxy {
                    Text(verbatim: L10n.tr(
                        "本次启动后 ↓%@ ↑%@",
                        NetworkSpeedFormatter.byteCount(feed.snapshot.totalDownloadedBytes),
                        NetworkSpeedFormatter.byteCount(feed.snapshot.totalUploadedBytes)
                    ))
                    .monospacedDigit()
                }
            }
            .font(.appCaption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassSurface(cornerRadius: 20, padding: 18, treatment: .regular)
    }

    private var history: NetworkThroughputHistory {
        switch scope {
        case .module:
            guard let egressModuleID else { return NetworkThroughputHistory() }
            return monitor.history(for: egressModuleID)
        case .proxy:
            return feed.proxyThroughput
        }
    }

    private var current: NetworkThroughput? {
        history.latest
    }

    private var note: String {
        switch scope {
        case .module:
            guard egressModuleID != nil else { return L10n.tr("出口模组未连接") }
            return L10n.tr("%@ 网卡的全部流量，和其他代理共用", interfaceName ?? moduleTitle)
        case .proxy:
            return L10n.tr("只算这个代理转发的流量")
        }
    }

    private func speedValue(title: String, color: Color, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(verbatim: title)
            }
            .font(.appCallout)
            .foregroundStyle(.secondary)
            Text(verbatim: value.map(NetworkSpeedFormatter.rate) ?? "—")
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(minWidth: 130, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ProxyThroughputChart: View {
    let history: NetworkThroughputHistory

    private struct Point: Identifiable {
        let id: Int
        let second: Int
        let value: Double
        let series: String
    }

    var body: some View {
        let samples = history.samples
        let offset = NetworkThroughputHistory.defaultCapacity - samples.count
        let download = samples.enumerated().map {
            Point(id: $0.offset, second: $0.offset + offset, value: $0.element.downloadBytesPerSecond, series: "download")
        }
        let upload = samples.enumerated().map {
            Point(id: $0.offset + 1_000, second: $0.offset + offset, value: $0.element.uploadBytesPerSecond, series: "upload")
        }
        Chart {
            ForEach(download) { point in
                LineMark(
                    x: .value("t", point.second),
                    y: .value("bytes", point.value),
                    series: .value("series", point.series)
                )
                .foregroundStyle(Color.blue)
                .interpolationMethod(.monotone)
            }
            ForEach(upload) { point in
                LineMark(
                    x: .value("t", point.second),
                    y: .value("bytes", point.value),
                    series: .value("series", point.series)
                )
                .foregroundStyle(Color.orange)
                .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...(NetworkThroughputHistory.defaultCapacity - 1))
        .chartYScale(domain: 0...max(history.peakBytesPerSecond * 1.15, 10_000))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(verbatim: NetworkSpeedFormatter.rate(bytes))
                            .font(.appMicro)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .accessibilityLabel(L10n.tr("最近 60 秒网速曲线"))
    }
}

// MARK: - Cells

private struct ProxyRequestTargetCell: View {
    let record: SOCKSProxyRequestRecord

    var body: some View {
        HStack(spacing: 6) {
            if let command = record.command {
                Text(verbatim: command == .udpAssociate ? "UDP" : "TCP")
                    .font(.appMicro)
                    .foregroundStyle(command == .udpAssociate ? Color.orange : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill((command == .udpAssociate ? Color.orange : Color.secondary).opacity(0.14))
                    )
            }
            Text(verbatim: ProxyRequestPresentation.target(record))
                .font(.appCallout.monospacedDigit())
                .foregroundStyle(record.target == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if record.command == .udpAssociate, record.destinationCount > 1 {
                Text(verbatim: "+\(record.destinationCount - 1)")
                    .font(.appCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ProxyRequestOutcomeBadge: View {
    let outcome: SOCKSProxyRequestOutcome

    var body: some View {
        Text(verbatim: ProxyRequestPresentation.title(outcome))
            .font(.appCaptionStrong)
            .foregroundStyle(ProxyRequestPresentation.tint(outcome))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(ProxyRequestPresentation.tint(outcome).opacity(0.14)))
            .fixedSize()
    }
}

// MARK: - Detail panel

private struct ProxyRequestDetailPanel: View {
    let record: SOCKSProxyRequestRecord
    let now: Date
    let egress: String
    let onClose: () -> Void
    let onDisconnect: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: record.isActive ? L10n.tr("活动中的请求") : L10n.tr("历史请求"))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: ProxyRequestPresentation.target(record))
                        .font(.appBodyStrong.monospaced())
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.appCaption.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(L10n.tr("关闭详情"))
                .accessibilityLabel(L10n.tr("关闭详情"))
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                row(L10n.tr("协议"), ProxyRequestPresentation.protocolTitle(record.command))
                row(L10n.tr("解析到"), record.resolvedAddress ?? "—", mono: true)
                row(L10n.tr("客户端"), record.client, mono: true)
                if record.command == .udpAssociate {
                    row(L10n.tr("目标数"), "\(record.destinationCount)", mono: true)
                }
                row(L10n.tr("出口"), egress)
                row(L10n.tr("开始"), ProxyRequestPresentation.time(record.startedAt), mono: true)
                row(L10n.tr("时长"), ProxyRequestPresentation.duration(record.duration(now: now)), mono: true)
                row(L10n.tr("下载"), NetworkSpeedFormatter.byteCount(record.downloadedBytes), mono: true)
                row(L10n.tr("上传"), NetworkSpeedFormatter.byteCount(record.uploadedBytes), mono: true)
                GridRow {
                    Text(verbatim: L10n.tr("结果"))
                        .font(.appCallout)
                        .foregroundStyle(.secondary)
                    ProxyRequestOutcomeBadge(outcome: record.outcome)
                }
            }

            if let explanation = ProxyRequestPresentation.explanation(record.outcome) {
                Text(verbatim: explanation)
                    .font(.appCallout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.red.opacity(0.08))
                    )
            }

            HStack(spacing: 8) {
                Button(action: copyTarget) {
                    Label(
                        didCopy ? L10n.tr("已复制") : L10n.tr("复制目标"),
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .adaptiveGlassButton(.regular)
                .disabled(record.target == nil)
                if record.isActive {
                    Button(L10n.tr("断开"), role: .destructive, action: onDisconnect)
                        .adaptiveGlassButton(.regular)
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(verbatim: title)
                .font(.appCallout)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(mono ? .appCallout.monospacedDigit() : .appCallout)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func copyTarget() {
        guard let target = record.target else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

// MARK: - Presentation

enum ProxyRequestPresentation {
    static func title(_ outcome: SOCKSProxyRequestOutcome) -> String {
        switch outcome {
        case .inProgress: return L10n.tr("进行中")
        case .completed: return L10n.tr("已结束")
        case .disconnected: return L10n.tr("已断开")
        case .connectionRefused: return L10n.tr("连接被拒")
        case .timedOut: return L10n.tr("超时")
        case .resolutionFailed: return L10n.tr("解析失败")
        case .networkUnreachable: return L10n.tr("网络不可达")
        case .hostUnreachable: return L10n.tr("主机不可达")
        case .authenticationFailed: return L10n.tr("认证失败")
        case .handshakeTimedOut: return L10n.tr("握手超时")
        case .sessionLimitReached: return L10n.tr("超出连接上限")
        case .failed: return L10n.tr("失败")
        }
    }

    static func tint(_ outcome: SOCKSProxyRequestOutcome) -> Color {
        switch outcome {
        case .inProgress: return .blue
        case .completed: return .green
        case .disconnected: return .secondary
        default: return .red
        }
    }

    static func explanation(_ outcome: SOCKSProxyRequestOutcome) -> String? {
        switch outcome {
        case .inProgress, .completed, .disconnected:
            return nil
        case .connectionRefused:
            return L10n.tr("目标端口拒绝连接（ECONNREFUSED），通常是对方服务没有运行。")
        case .timedOut:
            return L10n.tr(
                "%lld 秒内没有连上目标，可能是网络不通或被屏蔽。",
                Int64(SOCKSProxyLimits.connectTimeoutSeconds)
            )
        case .resolutionFailed:
            return L10n.tr("用模组的 DNS 解析这个域名没有结果。")
        case .networkUnreachable:
            return L10n.tr("模组的网络无法到达目标所在的网段。")
        case .hostUnreachable:
            return L10n.tr("没有到达目标主机的路由，或目标主机没有响应。")
        case .authenticationFailed:
            return L10n.tr("客户端提供的用户名或密码不对，连接在认证阶段被拒绝。")
        case .handshakeTimedOut:
            return L10n.tr(
                "客户端在 %lld 秒内没有完成 SOCKS 握手。",
                Int64(SOCKSProxyLimits.handshakeTimeoutSeconds)
            )
        case .sessionLimitReached:
            return L10n.tr(
                "这个代理已有 %lld 个连接，新连接被拒绝。",
                Int64(SOCKSProxyLimits.maximumSessionsPerProxy)
            )
        case .failed:
            return L10n.tr("代理无法完成这个请求，例如客户端使用了不支持的命令。")
        }
    }

    static func protocolTitle(_ command: SOCKSProxyRequestCommand?) -> String {
        switch command {
        case .tcpConnect: return "TCP（CONNECT）"
        case .udpAssociate: return "UDP（UDP ASSOCIATE）"
        case nil: return "—"
        }
    }

    static func target(_ record: SOCKSProxyRequestRecord) -> String {
        if let target = record.target { return target }
        switch (record.command, record.outcome) {
        case (_, .authenticationFailed): return L10n.tr("（未完成认证）")
        case (.udpAssociate, _): return L10n.tr("（尚无数据报）")
        case (nil, .inProgress): return L10n.tr("（握手中）")
        default: return L10n.tr("（未发出请求）")
        }
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int64(interval.rounded(.down))
        if seconds < 60 { return L10n.tr("%lld 秒", seconds) }
        if seconds < 3_600 { return L10n.tr("%lld 分 %lld 秒", seconds / 60, seconds % 60) }
        return L10n.tr("%lld 时 %lld 分", seconds / 3_600, (seconds % 3_600) / 60)
    }

    static func time(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .standard)
                .locale(AppLanguage.storedPreference.locale)
        )
    }
}
