import CellDockNetworkIPC
import SwiftUI

struct CellularNetworkModeMenu: View {
    @EnvironmentObject private var appState: AppState

    let moduleID: CellularModuleID
    let mode: CellularNetworkMode
    let isChanging: Bool
    let isEnabled: Bool
    var compact = false
    @State private var conflictingPreferredModuleID: CellularModuleID?

    var body: some View {
        Menu {
            modeButton(.preferred)
            modeButton(.standby)
            Divider()
            modeButton(.off)
        } label: {
            HStack(spacing: compact ? 5 : 7) {
                if isChanging {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: mode.systemImage)
                        .foregroundStyle(modeTint)
                }
                Text(mode.localizedTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.appSymbol(.indicator, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(compact ? .appCaption.weight(.semibold) : .appCallout.weight(.semibold))
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 4 : 6)
            .background(Color.secondary.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        // A cellular network change is one global transaction, so every module's
        // menu has to be inert while one is in flight. Only the modules that are
        // actually changing show a spinner, per the per-module progress rule.
        .disabled(!isEnabled || isChanging || appState.isChangingNetwork)
        .help(mode.localizedDetail)
        .accessibilityLabel(L10n.tr("蜂窝网络模式"))
        .accessibilityValue(mode.localizedTitle)
        .confirmationDialog(
            L10n.tr("切换蜂窝优先模组？"),
            isPresented: Binding(
                get: { conflictingPreferredModuleID != nil },
                set: { if !$0 { conflictingPreferredModuleID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("原模组保持连接")) {
                applyPreferredConflict(replacementMode: .standby)
            }
            Button(L10n.tr("完全关闭原模组"), role: .destructive) {
                applyPreferredConflict(replacementMode: .off)
            }
            Button(L10n.tr("取消"), role: .cancel) {
                conflictingPreferredModuleID = nil
            }
        } message: {
            Text(verbatim: conflictMessage)
        }
    }

    @ViewBuilder
    private func modeButton(_ candidate: CellularNetworkMode) -> some View {
        Button {
            select(candidate)
        } label: {
            Label(
                candidate.localizedTitle,
                systemImage: candidate == mode ? "checkmark" : candidate.systemImage
            )
        }
        .disabled(candidate == mode)
    }

    private func select(_ candidate: CellularNetworkMode) {
        if candidate == .preferred,
           let currentPreferred = appState.preferredCellularModuleID,
           currentPreferred != moduleID {
            conflictingPreferredModuleID = currentPreferred
            return
        }
        appState.setCellularNetworkMode(candidate, for: moduleID)
    }

    private func applyPreferredConflict(replacementMode: CellularNetworkMode) {
        guard conflictingPreferredModuleID != nil else { return }
        conflictingPreferredModuleID = nil
        appState.setCellularNetworkMode(
            .preferred,
            for: moduleID,
            replacingPreviousPreferredWith: replacementMode
        )
    }

    private var conflictMessage: String {
        guard let conflictingPreferredModuleID,
              let previous = appState.cellularModules.first(where: {
                  $0.id == conflictingPreferredModuleID
              }),
              let target = appState.cellularModules.first(where: { $0.id == moduleID }) else {
            return L10n.tr("请选择如何处理当前蜂窝优先模组。")
        }
        return L10n.tr(
            "%@ 当前为蜂窝优先。将 %@ 设为蜂窝优先后，如何处理原模组？",
            previous.displayName,
            target.displayName
        )
    }

    private var modeTint: Color {
        switch mode {
        case .off: return .secondary
        case .standby: return .blue
        case .preferred: return .green
        }
    }
}
