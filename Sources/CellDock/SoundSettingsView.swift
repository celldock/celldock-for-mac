import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SoundSettingsView: View {
    private static let customSoundID = "__custom__"
    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top),
        GridItem(.flexible(minimum: 0), spacing: 10, alignment: .top)
    ]

    @ObservedObject private var alertSounds = AlertSoundService.shared
    @State private var soundImportError: String?

    var body: some View {
        VStack(spacing: 16) {
            soundSection(
                .message,
                systemImage: "message.fill",
                tint: .blue,
                description: L10n.tr("收到新短信时播放一次")
            )
            soundSection(
                .incomingCall,
                systemImage: "phone.fill",
                tint: .green,
                description: L10n.tr("来电时循环播放，直到接听或挂断")
            )

            Label(
                L10n.tr("声音会从 Mac 扬声器播放；可随时试听或恢复默认。"),
                systemImage: "speaker.wave.2"
            )
            .font(.appCaption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .onDisappear {
            alertSounds.stopPreview()
        }
        .alert(
            L10n.tr("无法使用音频文件"),
            isPresented: Binding(
                get: { soundImportError != nil },
                set: { if !$0 { soundImportError = nil } }
            )
        ) {
            Button(L10n.tr("好"), role: .cancel) { soundImportError = nil }
        } message: {
            Text(soundImportError ?? L10n.tr("请选择其他音频文件。"))
        }
    }

    private func soundSection(
        _ kind: AlertSoundKind,
        systemImage: String,
        tint: Color,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.appSymbol(.rail, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title)
                        .font(.appBodyStrong)
                    Text(description)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if !alertSounds.isUsingDefault(kind) {
                    Button {
                        alertSounds.restoreDefault(for: kind)
                    } label: {
                        Label(L10n.tr("恢复默认"), systemImage: "arrow.counterclockwise")
                    }
                    .adaptiveGlassButton()
                    .controlSize(.small)
                }
            }
            .padding(16)

            Divider().padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(kind.bundledSounds) { sound in
                        soundOptionCard(
                            kind: kind,
                            id: sound.id,
                            title: sound.displayName,
                            duration: sound.duration,
                            tint: tint,
                            isSelected: alertSounds.selectedBundledSoundID(for: kind) == sound.id,
                            select: { selectBundledSound(sound, for: kind) },
                            preview: { previewBundledSound(sound, for: kind) }
                        )
                    }

                    if alertSounds.hasCustomSound(for: kind) {
                        soundOptionCard(
                            kind: kind,
                            id: Self.customSoundID,
                            title: alertSounds.displayName(for: kind),
                            duration: alertSounds.customSoundDuration(for: kind) ?? 0,
                            tint: tint,
                            isSelected: alertSounds.selectedBundledSoundID(for: kind) == nil,
                            select: {},
                            preview: { previewCustomSound(kind) }
                        )
                    }
                }

                Button {
                    chooseCustomSound(kind)
                } label: {
                    Label(L10n.tr("导入自定义声音…"), systemImage: "folder.badge.plus")
                }
                .adaptiveGlassButton()
                .controlSize(.small)
            }
            .padding(12)
        }
        .adaptiveGlassSurface(
            cornerRadius: 18,
            treatment: .regular,
            tint: tint.opacity(0.025)
        )
    }

    private func soundOptionCard(
        kind: AlertSoundKind,
        id: String,
        title: String,
        duration: TimeInterval,
        tint: Color,
        isSelected: Bool,
        select: @escaping () -> Void,
        preview: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.appSymbol(.button, weight: .semibold))
                        .foregroundStyle(isSelected ? tint : Color.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.appCaption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(formatDuration(duration))
                            .font(.appCaption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("选择%@", title))
            .accessibilityValue(isSelected ? L10n.tr("已选择") : L10n.tr("未选择"))

            Button(action: preview) {
                Image(
                    systemName: alertSounds.isPreviewPlaying(kind: kind, soundID: id)
                        ? "pause.fill"
                        : "play.fill"
                )
                .frame(width: 18, height: 18)
            }
            .adaptiveGlassButton()
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .help(
                alertSounds.isPreviewPlaying(kind: kind, soundID: id)
                    ? L10n.tr("暂停")
                    : L10n.tr("试听")
            )
            .accessibilityLabel(
                alertSounds.isPreviewPlaying(kind: kind, soundID: id)
                    ? L10n.tr("暂停%@", title)
                    : L10n.tr("试听%@", title)
            )
        }
        .adaptiveGlassSurface(
            cornerRadius: 13,
            padding: 10,
            treatment: .clear,
            tint: isSelected ? tint.opacity(0.12) : Color.clear,
            isInteractive: true
        )
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "--:--" }
        let totalSeconds = Int(duration)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func selectBundledSound(_ sound: BundledAlertSound, for kind: AlertSoundKind) {
        do {
            try alertSounds.selectBundledSound(sound, for: kind)
        } catch {
            soundImportError = error.localizedDescription
        }
    }

    private func previewBundledSound(_ sound: BundledAlertSound, for kind: AlertSoundKind) {
        do {
            try alertSounds.togglePreview(for: kind, sound: sound)
        } catch {
            soundImportError = error.localizedDescription
        }
    }

    private func previewCustomSound(_ kind: AlertSoundKind) {
        do {
            try alertSounds.toggleCustomPreview(for: kind)
        } catch {
            soundImportError = error.localizedDescription
        }
    }

    private func chooseCustomSound(_ kind: AlertSoundKind) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择%@", kind.title)
        panel.prompt = L10n.tr("选择")
        panel.message = L10n.tr("音频将复制到 CellDock 的应用支持目录，原文件可以安全移动或删除。")
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let sourceURL = panel.url else { return }
            Task { @MainActor in
                do {
                    try alertSounds.installCustomSound(from: sourceURL, for: kind)
                } catch {
                    soundImportError = error.localizedDescription
                }
            }
        }
    }
}
