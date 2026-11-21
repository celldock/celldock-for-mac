import SwiftUI

struct PhoneSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: PhoneWindowModel
    @ObservedObject var history: CallHistoryStore
    @ObservedObject var recordings: CallRecordingStore
    @ObservedObject var contacts: SystemContactStore

    @State private var hoveredCallID: CallHistoryRecord.ID?
    @State private var hoveredRecordingID: CallRecordingRecord.ID?

    var body: some View {
        List(selection: $model.selection) {
            Section(L10n.tr("资料库")) {
                navigationRow(.dialer)
                navigationRow(.contacts)
                Label(L10n.tr("查看全部"), systemImage: PhoneWindowSection.recents.systemImage)
                    .tag(PhoneWindowSection.recents)
                Label(L10n.tr("所有录音"), systemImage: PhoneWindowSection.recordings.systemImage)
                    .tag(PhoneWindowSection.recordings)
            }

            Section(L10n.tr("最近通话")) {
                ForEach(history.records.prefix(5)) { record in
                    recentCallRow(record)
                }

                if history.records.isEmpty {
                    sidebarEmptyRow(L10n.tr("暂无通话记录"))
                }
            }

            Section(L10n.tr("最近录音")) {
                ForEach(recordings.records.prefix(5)) { record in
                    recentRecordingRow(record)
                }

                if recordings.records.isEmpty {
                    sidebarEmptyRow(L10n.tr("暂无通话录音"))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial)
        .navigationTitle(L10n.tr("电话"))
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 240)
    }

    private func navigationRow(_ section: PhoneWindowSection) -> some View {
        Label {
            Text(verbatim: section.title)
        } icon: {
            Image(systemName: section.systemImage)
        }
            .tag(section)
    }

    private func recentCallRow(_ record: CallHistoryRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: callIcon(record))
                .font(.caption.weight(.semibold))
                .foregroundStyle(record.isMissed ? Color.red : Color.secondary)
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: appState.privacyPresentation.identity(
                    contactName: contacts.displayName(for: record.number),
                    number: record.number
                ))
                    .font(.callout)
                    .foregroundStyle(record.isMissed ? Color.red : Color.primary)
                    .lineLimit(1)

                Text(verbatim: [moduleName(record), record.startedAt.formatted(.dateTime.month().day().hour().minute())]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                call(record)
            } label: {
                Image(systemName: "phone.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!canDial(record))
            .opacity(hoveredCallID == record.id ? 1 : 0)
            .scaleEffect(hoveredCallID == record.id ? 1 : 0.9)
            .allowsHitTesting(hoveredCallID == record.id)
            .help(callAccessibilityLabel(record.number))
            .accessibilityLabel(callAccessibilityLabel(record.number))
            .accessibilityIdentifier("PhoneSidebarCall-\(record.id.uuidString)")
            .accessibilityHidden(hoveredCallID != record.id)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.activateFromRail(.recents)
        }
        .onHover { isHovered in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredCallID = isHovered ? record.id : nil
            }
        }
        .contextMenu {
            Button(L10n.tr("回拨"), systemImage: "phone") { call(record) }
                .disabled(!canDial(record))
            Button(L10n.tr("发短信"), systemImage: "message") {
                appState.showMessagesWindow(destination: record.number)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PhoneSidebarCallRow-\(record.id.uuidString)")
    }

    private func recentRecordingRow(_ record: CallRecordingRecord) -> some View {
        let isPlaying = recordings.playingRecordingID == record.id
        return HStack(spacing: 8) {
            Image(systemName: isPlaying ? "waveform.circle.fill" : "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: appState.privacyPresentation.recordingTitle(
                    customTitle: record.title,
                    contactName: contacts.displayName(for: record.number),
                    number: record.number
                ))
                    .font(.callout)
                    .lineLimit(1)

                Text(verbatim: recordingMetadata(record))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                recordings.play(record)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .opacity(hoveredRecordingID == record.id || isPlaying ? 1 : 0)
            .scaleEffect(hoveredRecordingID == record.id || isPlaying ? 1 : 0.9)
            .allowsHitTesting(hoveredRecordingID == record.id || isPlaying)
            .help(isPlaying ? L10n.tr("暂停录音") : L10n.tr("播放录音"))
            .accessibilityLabel(isPlaying ? L10n.tr("暂停录音") : L10n.tr("播放录音"))
            .accessibilityIdentifier("PhoneSidebarRecording-\(record.id.uuidString)")
            .accessibilityHidden(hoveredRecordingID != record.id && !isPlaying)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedRecordingID = record.id
            model.activateFromRail(.recordings)
        }
        .onHover { isHovered in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredRecordingID = isHovered ? record.id : nil
            }
        }
        .contextMenu {
            Button(isPlaying ? L10n.tr("暂停") : L10n.tr("播放"), systemImage: isPlaying ? "pause.fill" : "play.fill") {
                recordings.play(record)
            }
            Button(L10n.tr("在访达中显示"), systemImage: "folder") {
                recordings.reveal(record)
            }
            .disabled(appState.isPresentationPrivacyEnabled)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PhoneSidebarRecordingRow-\(record.id.uuidString)")
    }

    private func sidebarEmptyRow(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.leading, 23)
            .accessibilityHidden(true)
    }

    private func canDial(_ record: CallHistoryRecord) -> Bool {
        appState.moduleCanDial(nil) &&
            !appState.isChangingCall &&
            CallATParser.normalizedDialNumber(record.number) != nil
    }

    private func call(_ record: CallHistoryRecord) {
        guard canDial(record) else { return }
        model.dialNumber = record.number
        appState.dial(record.number)
    }

    private func moduleName(_ record: CallHistoryRecord) -> String? {
        guard let moduleID = record.moduleID,
              let name = appState.cellularModules.first(where: { $0.id == moduleID })?.displayName else {
            return nil
        }
        guard let simSlot = record.simSlot else { return name }
        return name + L10n.tr(" · 卡 %lld", Int64(simSlot))
    }

    private func callAccessibilityLabel(_ number: String) -> String {
        let identity = appState.privacyPresentation.identity(
            contactName: contacts.displayName(for: number),
            number: number
        )
        return L10n.tr("拨打 %@", identity)
    }

    private func callIcon(_ record: CallHistoryRecord) -> String {
        record.direction == .incoming
            ? "phone.arrow.down.left.fill"
            : "phone.arrow.up.right.fill"
    }

    private func recordingMetadata(_ record: CallRecordingRecord) -> String {
        let seconds = max(0, Int(record.duration.rounded()))
        let duration = seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "\(record.startedAt.formatted(.dateTime.month().day())) · \(duration)"
    }
}
