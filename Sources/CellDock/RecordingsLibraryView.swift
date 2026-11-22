import AppKit
import SwiftUI

struct RecordingsLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var recordings: CallRecordingStore
    @ObservedObject var contacts: SystemContactStore
    @Binding var selectedRecordingID: CallRecordingRecord.ID?
    @Binding var sidebarWidth: CGFloat
    var focusFirstItemRequest = false
    var didHandleFocusFirstItemRequest: () -> Void = {}

    @State private var searchText = ""
    @State private var directionFilter = 0
    @State private var deletingRecording: CallRecordingRecord?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var waveform: CallRecordingWaveformData?
    @State private var waveformError: String?
    @State private var loadingWaveformID: CallRecordingRecord.ID?
    @FocusState private var listFocused: Bool

    var body: some View {
        ResizableCommunicationSplit(sidebarWidth: $sidebarWidth) {
            recordingList
        } detail: {
            detail
                .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            selectFirstRecordingIfNeeded()
            loadSelectedWaveform()
            handleFocusFirstItemRequest()
        }
        .onChange(of: focusFirstItemRequest) { _, requested in
            if requested { handleFocusFirstItemRequest() }
        }
        .onChange(of: recordings.records.map(\.id)) { _, _ in
            selectFirstRecordingIfNeeded()
        }
        .onChange(of: appState.lineScope.line) { _, _ in
            if !filteredRecordingRecords.contains(where: { $0.id == selectedRecordingID }) {
                selectedRecordingID = filteredRecordingRecords.first?.id
            }
        }
        .onChange(of: selectedRecordingID) { _, _ in
            renameText = selectedRecording?.title ?? ""
            loadSelectedWaveform()
        }
        .onChange(of: appState.isPresentationPrivacyEnabled) { _, enabled in
            if enabled {
                isRenaming = false
                renameText = ""
            }
        }
        .confirmationDialog(
            "删除这段通话录音？",
            isPresented: Binding(
                get: { deletingRecording != nil },
                set: { if !$0 { deletingRecording = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除录音", role: .destructive) { deleteSelectedRecording() }
            Button("取消", role: .cancel) { deletingRecording = nil }
        } message: {
            Text("音频文件将从这台 Mac 永久删除；最近通话记录仍会保留。")
        }
        .alert("重命名录音", isPresented: $isRenaming) {
            TextField("录音名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") { saveRename() }
        } message: {
            Text("留空将恢复显示联系人或电话号码。")
        }
    }

    private var recordingList: some View {
        let resolver = appState.lineAppearanceResolver
        let visible = filteredRecordingRecords

        return VStack(spacing: 0) {
            TextField("搜索录音、联系人或号码", text: $searchText)
                .font(.appCallout)
                .communicationSearchField()
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            CommunicationGlassTabs(
                items: [(0, "全部"), (1, "呼入"), (2, "呼出")],
                selection: $directionFilter
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            List(visible) { record in
                recordingRow(record, line: resolver.appearance(for: line(of: record)))
                    .communicationSelectionHighlight(selectedRecordingID == record.id)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedRecordingID = record.id }
                    .accessibilityAddTraits(selectedRecordingID == record.id ? .isSelected : [])
                    .tag(record.id)
                    .contextMenu {
                        Button("播放或暂停", systemImage: "playpause") {
                            recordings.play(record)
                        }
                        Button("导出…", systemImage: "square.and.arrow.up") {
                            recordings.export(record)
                        }
                        .disabled(appState.isPresentationPrivacyEnabled)
                        Button("在访达中显示", systemImage: "folder") {
                            recordings.reveal(record)
                        }
                        .disabled(appState.isPresentationPrivacyEnabled)
                        Divider()
                        Button("删除", systemImage: "trash", role: .destructive) {
                            deletingRecording = record
                        }
                    }
            }
            .listStyle(.sidebar)
            .communicationEmphasizedSelection()
            .communicationInitialListFocus($listFocused)
            .scrollContentBackground(.hidden)
            .communicationSidebarScrollEdgeEffect()
        }
        .communicationSidebarColumnStyle()
        .communicationModuleFloatingSidebar()
    }

    private func recordingRow(_ record: CallRecordingRecord, line: LineAppearance) -> some View {
        let isActive = recordings.playingRecordingID == record.id
        return RecordingRowContent(
            title: displayName(for: record),
            address: record.number,
            detail: recordingDuration(record.duration),
            direction: record.direction,
            timestamp: CommunicationUI.listTimestamp(record.startedAt),
            isIncomplete: record.isIncomplete,
            playbackSymbol: isActive
                ? (recordings.isPlaybackPlaying ? "waveform" : "play.fill")
                : nil,
            line: line
        )
    }

    /// The line a recording was made on. Recordings made before lines were
    /// stored with them fall back to their call-history record.
    private func line(of record: CallRecordingRecord) -> CommunicationLine? {
        if let moduleID = record.moduleID {
            return CommunicationLine(moduleID: moduleID, simSlot: record.simSlot)
        }
        return appState.callHistory.records.first {
            $0.recordingID == record.id || (record.callID != nil && $0.id == record.callID)
        }?.line
    }

    @ViewBuilder
    private var detail: some View {
        if let record = selectedRecording {
            RecordingDetailPane(
                record: record,
                displayName: displayName(for: record),
                line: appState.lineAppearanceResolver.appearance(for: line(of: record)),
                waveform: waveform,
                waveformError: waveformError,
                recordings: recordings,
                onCall: {
                    guard !appState.blocksActionWhileViewingOfflineLine() else { return }
                    appState.showPhoneWindow(number: record.number)
                },
                onMessage: {
                    guard !appState.blocksActionWhileViewingOfflineLine() else { return }
                    appState.showMessagesWindow(destination: record.number)
                },
                onRename: beginRename,
                onExport: { recordings.export(record) },
                onReveal: { recordings.reveal(record) },
                onDelete: { deletingRecording = record }
            )
        } else {
            PhoneEmptyState(
                title: recordings.records.isEmpty ? L10n.tr("暂无通话录音") : L10n.tr("选择一段录音"),
                detail: recordings.records.isEmpty
                    ? L10n.tr("在通话中手动开始录音，结束后会保存在此 Mac。")
                    : L10n.tr("可播放、定位、重命名、导出或删除通话录音。"),
                systemImage: "waveform"
            )
        }
    }

    /// The recordings of the line picked in the module selector.
    private var filteredRecordingRecords: [CallRecordingRecord] {
        let scope = appState.lineScope
        let directional = recordings.records.filter { record in
            guard scope.contains(line(of: record)) else { return false }
            return directionFilter == 0 ||
                (directionFilter == 1 && record.direction == .incoming) ||
                (directionFilter == 2 && record.direction == .outgoing)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return directional }
        return directional.filter { record in
            record.number.localizedCaseInsensitiveContains(query) ||
                (record.title ?? "").localizedCaseInsensitiveContains(query) ||
                (contacts.displayName(for: record.number) ?? "")
                    .localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedRecording: CallRecordingRecord? {
        guard let selectedRecordingID else { return nil }
        return recordings.records.first { $0.id == selectedRecordingID }
    }

    private func selectFirstRecordingIfNeeded() {
        if let selectedRecordingID,
           recordings.records.contains(where: { $0.id == selectedRecordingID }) {
            return
        }
        selectedRecordingID = filteredRecordingRecords.first?.id
    }

    private func handleFocusFirstItemRequest() {
        guard focusFirstItemRequest else { return }
        selectedRecordingID = filteredRecordingRecords.first?.id
        didHandleFocusFirstItemRequest()
        listFocused = false
        DispatchQueue.main.async {
            listFocused = true
        }
    }

    private func loadSelectedWaveform() {
        guard let record = selectedRecording else {
            waveform = nil
            waveformError = nil
            loadingWaveformID = nil
            return
        }
        waveform = nil
        waveformError = nil
        loadingWaveformID = record.id
        CallRecordingWaveformLoader.shared.load(url: recordings.fileURL(for: record)) { result in
            guard selectedRecordingID == record.id else { return }
            loadingWaveformID = nil
            switch result {
            case let .success(loaded):
                waveform = loaded
            case let .failure(error):
                waveformError = error.localizedDescription
            }
        }
    }

    private func beginRename() {
        guard !appState.isPresentationPrivacyEnabled else { return }
        renameText = selectedRecording?.title ?? ""
        isRenaming = true
    }

    private func saveRename() {
        guard let selectedRecording else { return }
        recordings.rename(selectedRecording, title: renameText)
    }

    private func deleteSelectedRecording() {
        guard let deletingRecording else { return }
        recordings.delete(deletingRecording)
        self.deletingRecording = nil
        selectFirstRecordingIfNeeded()
        loadSelectedWaveform()
    }

    private func displayName(for record: CallRecordingRecord) -> String {
        appState.privacyPresentation.recordingTitle(
            customTitle: record.title,
            contactName: contacts.displayName(for: record.number),
            number: record.number
        )
    }

}

private struct RecordingDetailPane: View {
    @EnvironmentObject private var appState: AppState
    let record: CallRecordingRecord
    let displayName: String
    let line: LineAppearance
    let waveform: CallRecordingWaveformData?
    let waveformError: String?
    @ObservedObject var recordings: CallRecordingStore
    let onCall: () -> Void
    let onMessage: () -> Void
    let onRename: () -> Void
    let onExport: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            AdaptiveGlassContainer(spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    identityHeader

                    RecordingPlayerCard(
                        record: record,
                        waveform: waveform,
                        waveformError: waveformError,
                        recordings: recordings
                    )

                    RecordingInformationCard(
                        record: record,
                        line: line,
                        fileURL: recordings.fileURL(for: record)
                    )

                    actionBar

                    if let error = recordings.lastError {
                        Label(L10n.tr(error), systemImage: "exclamationmark.triangle.fill")
                            .font(.appCaption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
                .frame(maxWidth: 940, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .communicationDetailColumnStyle()
    }

    private var identityHeader: some View {
        HStack(spacing: 16) {
            identity
                .layoutPriority(1)

            Spacer(minLength: 12)

            headerActions
        }
        .adaptiveGlassSurface(
            cornerRadius: 20,
            padding: 16,
            treatment: .regular
        )
    }

    private var identity: some View {
        HStack(spacing: 16) {
            ContactFaceAvatar(
                address: record.number,
                size: AppMetrics.Avatar.large
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.appTitle)
                    .lineLimit(1)
                Text(appState.privacyPresentation.phoneNumber(record.number))
                    .font(.appCallout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(headerMetadata)
                    .font(.appCaption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var headerActions: some View {
        VStack(spacing: 8) {
            Button(action: onCall) {
                Label("回拨", systemImage: "phone")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .adaptiveGlassButton()
            .controlSize(.small)
            .frame(width: 92)

            Button(action: onMessage) {
                Label("发短信", systemImage: "message")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .adaptiveGlassButton()
            .controlSize(.small)
            .frame(width: 92)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: onRename) {
                Label("重新命名", systemImage: "pencil")
            }
            .adaptiveGlassButton()
            .disabled(appState.isPresentationPrivacyEnabled)
            .help(appState.isPresentationPrivacyEnabled
                ? L10n.tr("关闭演示隐私保护后可重命名")
                : L10n.tr("重新命名录音"))

            Button(action: onExport) {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .adaptiveGlassButton()
            .disabled(appState.isPresentationPrivacyEnabled)
            .help(appState.isPresentationPrivacyEnabled
                ? L10n.tr("关闭演示隐私保护后可导出")
                : L10n.tr("导出录音"))

            Button(action: onReveal) {
                Label("在访达中显示", systemImage: "folder")
            }
            .adaptiveGlassButton()
            .disabled(appState.isPresentationPrivacyEnabled)
            .help(appState.isPresentationPrivacyEnabled
                ? L10n.tr("关闭演示隐私保护后可在访达中显示")
                : L10n.tr("在访达中显示"))

            Spacer(minLength: 12)

            Button(role: .destructive, action: onDelete) {
                Label("删除录音", systemImage: "trash")
            }
            .adaptiveGlassButton()
            .tint(.red)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerMetadata: String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.storedPreference.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmm")
        let direction = record.direction == .incoming ? L10n.tr("呼入") : L10n.tr("呼出")
        return L10n.tr("%@ · %@ · %@", formatter.string(from: record.startedAt), direction, spokenDuration(record.duration))
    }
}

private struct RecordingPlayerCard: View {
    @EnvironmentObject private var appState: AppState
    let record: CallRecordingRecord
    let waveform: CallRecordingWaveformData?
    let waveformError: String?
    @ObservedObject var recordings: CallRecordingStore

    @State private var showsVolume = false

    private let playbackControlSize: CGFloat = 38

    var body: some View {
        VStack(spacing: 14) {
            waveformArea

            HStack(spacing: 10) {
                Text(recordingDuration(position))
                    .frame(width: 50, alignment: .leading)

                Slider(value: progressBinding, in: 0 ... max(duration, 0.1))
                    .accessibilityLabel(L10n.tr("播放进度"))
                    .accessibilityValue(L10n.tr(
                        "播放进度：%@，共 %@",
                        recordingDuration(position),
                        recordingDuration(duration)
                    ))

                Text(recordingDuration(duration))
                    .frame(width: 50, alignment: .trailing)
            }
            .font(.appCaption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            playbackControls
        }
        .adaptiveGlassSurface(
            cornerRadius: 22,
            padding: 18,
            treatment: .regular
        )
    }

    @ViewBuilder
    private var waveformArea: some View {
        if let waveform {
            RecordingWaveformView(
                waveform: waveform,
                progress: duration > 0 ? position / duration : 0,
                currentTime: position,
                duration: duration,
                onSeek: { progress in
                    recordings.seekPlayback(record, to: duration * progress)
                }
            )
            .frame(height: 184)
        } else if let waveformError {
            VStack(spacing: 8) {
                Image(systemName: "waveform.slash")
                    .font(.appSymbol(.rail))
                Text(waveformError)
                    .font(.appCallout)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 184)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在生成声纹…")
                    .font(.appCallout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 184)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                ensurePrepared()
                recordings.skipPlayback(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.appSymbol(.button))
                    .frame(width: playbackControlSize, height: playbackControlSize)
            }
            .adaptiveGlassButton()
            .buttonBorderShape(.circle)
            .help(L10n.tr("后退 15 秒"))

            Button {
                recordings.play(record)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.appSymbol(.button, weight: .semibold))
                    .frame(width: playbackControlSize, height: playbackControlSize)
            }
            .adaptiveGlassButton(.accented)
            .buttonBorderShape(.circle)
            .help(isPlaying ? L10n.tr("暂停") : L10n.tr("播放"))

            Button {
                ensurePrepared()
                recordings.skipPlayback(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .font(.appSymbol(.button))
                    .frame(width: playbackControlSize, height: playbackControlSize)
            }
            .adaptiveGlassButton()
            .buttonBorderShape(.circle)
            .help(L10n.tr("前进 15 秒"))

            Button {
                recordings.setPlaybackRate(nextPlaybackRate)
            } label: {
                Text(playbackRateLabel)
                    .font(.appCaption.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: playbackControlSize, height: playbackControlSize)
            }
            .adaptiveGlassButton()
            .buttonBorderShape(.circle)
            .help(L10n.tr("切换播放速度"))

            Button {
                showsVolume.toggle()
            } label: {
                Image(systemName: volumeIcon)
                    .font(.appSymbol(.button))
                    .frame(width: playbackControlSize, height: playbackControlSize)
            }
            .adaptiveGlassButton()
            .buttonBorderShape(.circle)
            .help(L10n.tr("调整音量"))
            .popover(isPresented: $showsVolume, arrowEdge: .bottom) {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                    Slider(value: volumeBinding, in: 0 ... 1)
                    Image(systemName: "speaker.wave.3.fill")
                }
                .padding(14)
                .frame(width: 230)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var isActiveRecording: Bool {
        recordings.playingRecordingID == record.id
    }

    private var isPlaying: Bool {
        isActiveRecording && recordings.isPlaybackPlaying
    }

    private var position: TimeInterval {
        isActiveRecording ? recordings.playbackPosition : 0
    }

    private var duration: TimeInterval {
        isActiveRecording && recordings.playbackDuration > 0
            ? recordings.playbackDuration
            : record.duration
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { position },
            set: { recordings.seekPlayback(record, to: $0) }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(recordings.playbackVolume) },
            set: { recordings.setPlaybackVolume(Float($0)) }
        )
    }

    private var playbackRateLabel: String {
        let rate = recordings.playbackRate
        return rate.rounded() == rate ? "\(Int(rate))×" : "\(rate.formatted())×"
    }

    private var nextPlaybackRate: Float {
        let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]
        guard let index = rates.firstIndex(of: recordings.playbackRate) else { return 1 }
        return rates[(index + 1) % rates.count]
    }

    private var volumeIcon: String {
        switch recordings.playbackVolume {
        case ...0: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private func ensurePrepared() {
        if !isActiveRecording {
            recordings.seekPlayback(record, to: 0)
        }
    }
}

private struct RecordingWaveformView: View {
    let waveform: CallRecordingWaveformData
    let progress: Double
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (Double) -> Void

    @State private var isHovering = false

    private let labelWidth: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let topInset: CGFloat = 24
                let rightInset: CGFloat = 4
                let availableWidth = max(size.width - labelWidth - rightInset, 1)
                let remoteY = topInset + (size.height - topInset) * 0.28
                let localY = topInset + (size.height - topInset) * 0.72
                let laneHeight = (size.height - topInset) * 0.32

                context.draw(
                    Text("对方").font(.appCaption).foregroundStyle(.secondary),
                    at: CGPoint(x: 0, y: remoteY),
                    anchor: .leading
                )
                context.draw(
                    Text("本机").font(.appCaption).foregroundStyle(.secondary),
                    at: CGPoint(x: 0, y: localY),
                    anchor: .leading
                )

                drawLane(
                    context: &context,
                    values: waveform.remote,
                    centerY: remoteY,
                    height: laneHeight,
                    color: .blue,
                    labelWidth: labelWidth,
                    availableWidth: availableWidth
                )
                drawLane(
                    context: &context,
                    values: waveform.local,
                    centerY: localY,
                    height: laneHeight,
                    color: .indigo,
                    labelWidth: labelWidth,
                    availableWidth: availableWidth
                )

                let resolvedProgress = min(max(progress, 0), 1)
                let playheadX = labelWidth + availableWidth * resolvedProgress
                var playhead = Path()
                playhead.move(to: CGPoint(x: playheadX, y: topInset - 3))
                playhead.addLine(to: CGPoint(x: playheadX, y: size.height - 4))
                context.stroke(playhead, with: .color(.blue), lineWidth: 1.5)
                context.fill(
                    Path(ellipseIn: CGRect(x: playheadX - 4, y: topInset - 7, width: 8, height: 8)),
                    with: .color(.blue)
                )

                let timestamp = context.resolve(
                    Text(recordingDuration(currentTime))
                        .font(.appMicro.monospacedDigit())
                        .foregroundStyle(.blue)
                )
                let textSize = timestamp.measure(in: CGSize(width: 80, height: 18))
                let bubbleWidth = textSize.width + 12
                let bubbleRect = CGRect(
                    x: min(max(labelWidth, playheadX - bubbleWidth / 2), size.width - bubbleWidth),
                    y: 0,
                    width: bubbleWidth,
                    height: 19
                )
                context.fill(
                    Path(roundedRect: bubbleRect, cornerRadius: 9),
                    with: .color(Color.blue.opacity(0.10))
                )
                context.stroke(
                    Path(roundedRect: bubbleRect, cornerRadius: 9),
                    with: .color(Color.blue.opacity(0.45)),
                    lineWidth: 0.7
                )
                context.draw(timestamp, at: CGPoint(x: bubbleRect.midX, y: bubbleRect.midY))
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        onSeek(progress(at: value.location.x, width: proxy.size.width))
                    }
            )
        }
        .onDisappear {
            if isHovering { NSCursor.arrow.set() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("双声道录音声纹"))
        .accessibilityValue(L10n.tr(
            "对方为左声道，本机为右声道，当前 %@",
            recordingDuration(currentTime)
        ))
        .accessibilityAdjustableAction { direction in
            let step = duration > 0 ? min(5 / duration, 0.1) : 0.05
            switch direction {
            case .increment: onSeek(min(progress + step, 1))
            case .decrement: onSeek(max(progress - step, 0))
            @unknown default: break
            }
        }
    }

    private func drawLane(
        context: inout GraphicsContext,
        values: [Float],
        centerY: CGFloat,
        height: CGFloat,
        color: Color,
        labelWidth: CGFloat,
        availableWidth: CGFloat
    ) {
        guard !values.isEmpty else { return }
        let targetCount = max(1, min(values.count, Int(availableWidth / 2.2)))
        let step = Double(values.count) / Double(targetCount)
        let lineWidth = max(1.2, min(2.2, availableWidth / CGFloat(targetCount) * 0.62))
        let resolvedProgress = min(max(progress, 0), 1)

        for index in 0 ..< targetCount {
            let sourceIndex = min(values.count - 1, Int(Double(index) * step))
            let amplitude = max(CGFloat(values[sourceIndex]), 0.035)
            let x = labelWidth + (CGFloat(index) + 0.5) / CGFloat(targetCount) * availableWidth
            let barHeight = max(2, height * amplitude)
            var bar = Path()
            bar.move(to: CGPoint(x: x, y: centerY - barHeight / 2))
            bar.addLine(to: CGPoint(x: x, y: centerY + barHeight / 2))
            let sampleProgress = Double(index) / Double(max(targetCount - 1, 1))
            let barColor = sampleProgress <= resolvedProgress
                ? color
                : Color.secondary.opacity(0.28)
            context.stroke(
                bar,
                with: .color(barColor),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }
    }

    private func progress(at x: CGFloat, width: CGFloat) -> Double {
        let availableWidth = max(width - labelWidth - 4, 1)
        return min(max(Double((x - labelWidth) / availableWidth), 0), 1)
    }
}

private struct RecordingInformationCard: View {
    let record: CallRecordingRecord
    let line: LineAppearance
    let fileURL: URL

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 22) {
                recordingInformation
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                channelInformation
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 18) {
                recordingInformation
                Divider()
                channelInformation
            }
        }
        .adaptiveGlassSurface(
            cornerRadius: 20,
            padding: 16,
            treatment: .regular
        )
    }

    private var recordingInformation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("录音信息")
                .font(.appHeadline)
            informationRow("录制时间", value: formattedDate)
            informationRow(
                "通话方向",
                value: record.direction == .incoming ? L10n.tr("呼入") : L10n.tr("呼出")
            )
            HStack(alignment: .center, spacing: 12) {
                Text(L10n.tr("线路"))
                    .font(.appCallout)
                    .foregroundStyle(.secondary)
                Spacer()
                LineFieldValue(appearance: line)
            }
            informationRow("文件大小", value: fileSize)
        }
    }

    private var channelInformation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("声道")
                .font(.appHeadline)
            channelRow(color: .blue, title: "对方", value: L10n.tr("左声道"))
            channelRow(color: .indigo, title: "本机", value: L10n.tr("右声道"))
            Label("仅保存在这台 Mac", systemImage: "internaldrive")
                .font(.appCaption)
                .foregroundStyle(.secondary)
        }
    }

    private func informationRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L10n.tr(title))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
        .font(.appCallout)
    }

    private func channelRow(color: Color, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(L10n.tr(title))
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.appCallout)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.storedPreference.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmm")
        return formatter.string(from: record.startedAt)
    }

    private var fileSize: String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return byteCount > 0
            ? ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            : L10n.tr("尚未读取")
    }
}

private func recordingDuration(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration.rounded()))
    if total >= 3_600 {
        return String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
}

private func spokenDuration(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration.rounded()))
    let hours = total / 3_600
    let minutes = (total / 60) % 60
    let seconds = total % 60
    if hours > 0 {
        return L10n.tr(
            "%lld小时%lld分%lld秒",
            Int64(hours),
            Int64(minutes),
            Int64(seconds)
        )
    }
    return L10n.tr("%lld分%lld秒", Int64(minutes), Int64(seconds))
}
