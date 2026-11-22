import Foundation

final class ModuleVoiceRuntime {
    typealias Manifest = ModuleVoiceManifest

    private enum ResourceSource {
        case payload(URL)
#if DEBUG
        case directory(URL)
#endif
    }

    enum RuntimeError: AppLocalizedError {
        case resourcesMissing
        case invalidManifest(String)
        case componentMissing(String)
        case moduleCommand(String)

        var errorDescription: String? {
            switch self {
            case .resourcesMissing:
                return L10n.tr("应用包中缺少 QDC507 通话组件。")
            case let .invalidManifest(message):
                return L10n.tr("QDC507 通话组件清单无效：%@", message)
            case let .componentMissing(name):
                return L10n.tr("应用包中缺少通话组件：%@", name)
            case let .moduleCommand(message):
                return message
            }
        }
    }

    private let controller: ADBModuleController
    private let resourceSource: ResourceSource
    private let manifest: Manifest
    private let remoteDirectory = "/tmp/celldock-call"
    private let pidFile = "/run/celldock-pcm-bridge.pid"
    private let logFile = "/run/celldock-pcm-bridge.log"
    private let routePIDFile = "/run/celldock-voice-route.pid"
    private let routeLogFile = "/run/celldock-voice-route.log"
    private let calibrationPIDFile = "/run/celldock-alsaucm.pid"
    private let calibrationLogFile = "/run/celldock-alsaucm.log"
    private var prepared = false

    init(locationID: UInt32) throws {
        controller = ADBModuleController(locationID: locationID)
        guard let source = Self.locateResourceSource() else {
            throw RuntimeError.resourcesMissing
        }
        let package: ModuleVoicePayload.Package
        do {
            package = try Self.loadPackage(from: source)
        } catch {
            throw RuntimeError.invalidManifest(error.localizedDescription)
        }
        resourceSource = source
        manifest = package.manifest
    }

    func probeControlChannel() throws {
        let result = try controller.shellChecked("id -u", timeout: 8)
        guard result.status == 0,
              result.output.split(whereSeparator: { $0.isWhitespace }).contains("0") else {
            throw RuntimeError.moduleCommand(L10n.tr("模块 ADB 没有 root 控制权限。"))
        }
    }

    func recoverECMNetworkLink() throws {
        let command =
            "test -d /sys/class/net/ecm0 || { echo '模块缺少 ecm0'; exit 20; }; " +
            "test -d /sys/class/net/bridge0 || { echo '模块缺少 bridge0'; exit 21; }; " +
            "ip -o link show ecm0 | grep -q 'master bridge0' || " +
            "{ echo 'ecm0 未连接到 bridge0'; exit 22; }; " +
            "ip -o -4 addr show bridge0 | grep -q '192\\.168\\.225\\.1/24' || " +
            "{ echo '模块 ECM 网关未就绪'; exit 23; }; " +
            "ps -A | grep -q '[d]nsmasq.*bridge0' || " +
            "{ echo '模块 DHCP 服务未运行'; exit 24; }; " +
            // Do not flap ecm0 here. Dropping a healthy carrier makes macOS
            // discard its lease and also restarts this module's 15-second
            // bridge forwarding delay, which can turn recovery into a loop.
            "ip link set bridge0 up && ip link set ecm0 up || " +
            "{ echo '模块 ECM 接口无法启用'; exit 25; }; " +
            "n=0; while test \"$(cat /sys/class/net/ecm0/carrier)\" != 1 && " +
            "test \"$n\" -lt 10; do sleep 1; n=$((n+1)); done; " +
            "test \"$(cat /sys/class/net/ecm0/carrier)\" = 1 || " +
            "{ echo '模块 ECM carrier 未恢复'; exit 25; }; " +
            // A newly created bridge port still needs its forwarding delay.
            // Healthy, already-forwarding links take the fast path and keep
            // the current data plane completely undisturbed.
            "if test \"$(cat /sys/class/net/bridge0/brif/ecm0/state 2>/dev/null)\" != 3; " +
            "then n=0; while test \"$n\" -lt 16; do sleep 1; n=$((n+1)); done; fi; " +
            "test \"$(cat /sys/class/net/bridge0/brif/ecm0/state 2>/dev/null)\" = 3 || " +
            "{ echo '模块 ECM bridge 未进入转发状态'; exit 26; }"
        let result = try controller.shellChecked(command, timeout: 30)
        guard result.status == 0 else {
            throw RuntimeError.moduleCommand(
                result.output.isEmpty
                    ? L10n.tr("模块 ECM 链路恢复返回状态 %d。", result.status)
                    : result.output
            )
        }
    }

    /// Reads the module-side `vowifi-go` control host. A missing host is a
    /// normal `supported=0` answer, not a command failure, so the UI can
    /// explain it instead of surfacing a shell error.
    func voWiFiRuntimeStatus() throws -> VoWiFiRuntimeStatus {
        let result = try controller.shellChecked(VoWiFiRuntimeControl.statusCommand, timeout: 12)
        guard result.status == 0 else {
            throw RuntimeError.moduleCommand(
                result.output.isEmpty
                    ? L10n.tr("读取模组 VoWiFi 状态失败。")
                    : result.output
            )
        }
        return VoWiFiRuntimeStatus.parse(keyValueOutput: result.output)
    }

    /// Admits one session. `vowifi-go` startup is asynchronous, so this only
    /// confirms that the host accepted the request and is now running *our*
    /// session; SIM/ISIM AKA, SWu and IMS progress are observed by polling.
    func startVoWiFiRuntime(_ request: VoWiFiSessionRequest) throws -> VoWiFiRuntimeStatus {
        let before = try voWiFiRuntimeStatus()
        guard before.isSupported else {
            throw RuntimeError.moduleCommand(before.localizedUnsupportedReason)
        }
        // The host keeps one Instance; starting over a live session would leave
        // the previous SOCKS5 association orphaned inside the runtime.
        if before.isRunning {
            try? stopVoWiFiRuntime()
        }
        let result = try controller.shellChecked(
            try VoWiFiRuntimeControl.startCommand(request),
            timeout: 30
        )
        guard result.status == 0 else {
            throw RuntimeError.moduleCommand(
                result.output.isEmpty
                    ? L10n.tr("模组拒绝启动 VoWiFi 运行时。")
                    : result.output
            )
        }
        let after = try voWiFiRuntimeStatus()
        guard after.isRunning, after.sessionID == request.sessionID else {
            throw RuntimeError.moduleCommand(
                after.hasRuntimeError
                    ? after.localizedFailureReason
                    : L10n.tr("模组没有确认新的 VoWiFi 会话。")
            )
        }
        return after
    }

    /// Deliberately does not read the status back: the controller re-polls
    /// immediately afterwards, and app termination cannot afford a second
    /// round trip on the shared ADB channel.
    func stopVoWiFiRuntime(timeout: TimeInterval = 20) throws {
        let result = try controller.shellChecked(VoWiFiRuntimeControl.stopCommand, timeout: timeout)
        guard result.status == 0 else {
            throw RuntimeError.moduleCommand(
                result.output.isEmpty
                    ? L10n.tr("模组拒绝停止 VoWiFi 运行时。")
                    : result.output
            )
        }
    }

    func prepare() throws -> String {
        if prepared { return manifest.runtimeVersion }
        try probeControlChannel()
        let release = try controller.shellChecked("uname -r", timeout: 8)
        guard release.status == 0,
              release.output.split(whereSeparator: { $0.isWhitespace })
                .contains(Substring(manifest.kernelRelease)) else {
            throw RuntimeError.moduleCommand(
                L10n.tr(
                    "模块内核版本与通话驱动不匹配；需要 %@，实际为 %@",
                    manifest.kernelRelease,
                    release.output.isEmpty ? L10n.tr("未知") : release.output
                )
            )
        }
        try checked("mkdir -p '\(remoteDirectory)' && chmod 700 '\(remoteDirectory)'")
        var modulesLoadedHere: [Manifest.KernelModule] = []
        defer { try? removeRemoteKernelModuleFiles() }

        do {
            let package = try Self.loadPackage(from: resourceSource)
            guard package.manifest == manifest else {
                throw RuntimeError.invalidManifest(L10n.tr("资源包在初始化后发生变化"))
            }
            for entry in manifest.files {
                guard let data = package.components[entry.name] else {
                    throw RuntimeError.componentMissing(entry.name)
                }
                try uploadVerified(data, entry: entry)
            }

            if try !soundDevicesReady() {
                let legacyDriver = try controller.shellChecked(
                    "grep -q '^qdc507_afe ' /proc/modules",
                    timeout: 8
                )
                if legacyDriver.status == 0 {
                    throw RuntimeError.moduleCommand(
                        L10n.tr(
                            "检测到旧版 qdc507_afe 声卡仍在内核中；为避免热切换语音驱动，请重启模块后再试。"
                        )
                    )
                }
                guard legacyDriver.status == 1 else {
                    throw RuntimeError.moduleCommand(
                        legacyDriver.output.isEmpty
                            ? L10n.tr("无法核对旧版音频驱动状态。")
                            : legacyDriver.output
                    )
                }
                for module in manifest.modules {
                    let present = try controller.shellChecked(
                        "grep -q '^\(module.name) ' /proc/modules",
                        timeout: 8
                    )
                    if present.status == 0 { continue }
                    guard present.status == 1 else {
                        throw RuntimeError.moduleCommand(
                            present.output.isEmpty
                                ? L10n.tr("无法读取模块驱动列表。")
                                : present.output
                        )
                    }
                    let result = try controller.shellChecked(
                        "insmod '\(remoteDirectory)/\(module.file)'",
                        timeout: 20
                    )
                    guard result.status == 0 else {
                        let diagnostics = try? controller.shellChecked(
                            "dmesg | tail -n 80",
                            timeout: 8
                        )
                        let detail = [result.output, diagnostics?.output]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        throw RuntimeError.moduleCommand(
                            detail.isEmpty ? L10n.tr("模块音频驱动加载失败。") : detail
                        )
                    }
                    modulesLoadedHere.append(module)
                    try removeRemoteComponent(module.file)
                }
            }
            try removeRemoteKernelModuleFiles()
            guard try waitForSoundDevices() else {
                let diagnostics = try? controller.shellChecked("dmesg | tail -n 80", timeout: 8)
                throw RuntimeError.moduleCommand(
                    diagnostics?.output.isEmpty == false
                        ? diagnostics!.output
                        : L10n.tr("音频驱动已加载，但 ALSA 设备没有出现。")
                )
            }

            try ensureVoiceCalibrationService()

            let voiceEndpoints = try controller.shellChecked(
                "test -c /dev/ttyGS0 && test -p /run/voc_svr",
                timeout: 8
            )
            guard voiceEndpoints.status == 0 else {
                throw RuntimeError.moduleCommand(
                    L10n.tr("模块缺少 ttyGS0 或 voc_svr，无法建立 USB 通话桥。")
                )
            }

            let helperPath = "\(remoteDirectory)/\(manifest.helper)"
            let check = try controller.shellChecked(
                "'\(helperPath)' --check",
                timeout: 15
            )
            guard check.status == 0 else {
                throw RuntimeError.moduleCommand(
                    check.output.isEmpty ? L10n.tr("模块 PCM 桥自检失败。") : check.output
                )
            }
        } catch {
            let rollbackError = unloadModulesLoadedHere(modulesLoadedHere)
            if let rollbackError, !rollbackError.isEmpty {
                throw RuntimeError.moduleCommand(
                    L10n.tr(
                        "%@\n驱动回滚未完整完成：%@",
                        error.localizedDescription,
                        rollbackError
                    )
                )
            }
            throw error
        }
        prepared = true
        return manifest.runtimeVersion
    }

    func startBridge() throws {
        throw RuntimeError.moduleCommand(
            L10n.tr(
                "QDC507 的 interface 1 原始 PCM 备用桥已禁用；当前只允许已实机验证的 UAC 通话路径。"
            )
        )
    }

    func startRouteOnly() throws {
        _ = try prepare()
        if (try? voiceRouteIsReady()) == true { return }

        let helperPath = "\(remoteDirectory)/\(manifest.helper)"
        let command = "rm -f '\(routePIDFile)' '\(routeLogFile)'; " +
            "nohup '\(helperPath)' --voice-route-session --verbose " +
            "</dev/null >> '\(routeLogFile)' 2>&1 & pid=$!; " +
            "starttime=$(cut -d ' ' -f 22 \"/proc/$pid/stat\" 2>/dev/null); " +
            "case \"$pid:$starttime\" in :*|*:|*[!0-9:]*) false;; *) " +
            "printf '%s %s\\n' \"$pid\" \"$starttime\" > '\(routePIDFile)';; esac"
        var launchFailure: String?
        do {
            let result = try controller.shellChecked(command, timeout: 8)
            if result.status != 0 {
                launchFailure = result.output.isEmpty
                    ? L10n.tr("启动命令返回状态 %d", result.status)
                    : result.output
            }
        } catch {
            // audio_enable=1 can momentarily re-enumerate the USB gadget after
            // the helper and PID file are already live. Reconnect and verify
            // the owned process instead of treating the lost shell reply as a
            // failed start.
            launchFailure = error.localizedDescription
        }

        for _ in 0 ..< 30 {
            if (try? voiceRouteIsReady()) == true { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let log = (try? routeLog()) ?? ""
        let details = [launchFailure, log.isEmpty ? nil : log]
            .compactMap { $0 }
            .joined(separator: "\n")
        throw RuntimeError.moduleCommand(
            details.isEmpty ? L10n.tr("模块 D4/UAC 语音路由没有进入 RUNNING。") : details
        )
    }

    func stopRouteOnly() throws {
        let helperPath = "\(remoteDirectory)/\(manifest.helper)"
        let stopCommand = "helper_stopped=1; " +
            "is_owned() { " +
            "current_start=$(cut -d ' ' -f 22 \"/proc/$pid/stat\" 2>/dev/null); " +
            "argv0=$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p'); " +
            "args=$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null); " +
            "test \"$current_start\" = \"$expected_start\" && " +
            "test \"$argv0\" = '\(helperPath)' && " +
            "printf '%s\\n' \"$args\" | grep -q '^--voice-route-session$'; }; " +
            "if test -s '\(routePIDFile)'; then " +
            "read pid expected_start < '\(routePIDFile)' || true; " +
            "case \"$pid:$expected_start\" in :*|*:|*[!0-9:]*) true;; *) " +
            "if is_owned; then kill -TERM \"$pid\" 2>/dev/null || true; " +
            "n=0; while is_owned && test \"$n\" -lt 50; do " +
            "sleep 0.1; n=$((n+1)); done; is_owned && helper_stopped=0 || true; fi;; esac; fi; " +
            "test \"$helper_stopped\" -eq 1 && rm -f '\(routePIDFile)'"
        _ = try? controller.shellChecked(stopCommand, timeout: 8)

        var stopped = false
        for _ in 0 ..< 20 {
            if (try? voiceRouteIsStopped()) == true {
                stopped = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard stopped else {
            throw RuntimeError.moduleCommand(
                L10n.tr("D4 语音 helper 未确认正常退出；为保留 mixer 回滚，没有发送 SIGKILL。")
            )
        }

        var cleanupFailure: String?
        for _ in 0 ..< 5 {
            do {
                let result = try controller.shellChecked(
                    "echo 0 > /sys/class/android_usb/f_audio/audio_enable; " +
                        "if test -p /run/voc_svr; then " +
                        "printf 'T\\n' > /run/voc_svr; " +
                        "printf 'T\\n' > /run/voc_svr; " +
                        "printf 'B\\n' > /run/voc_svr; fi; " +
                        "test \"$(cat /sys/class/android_usb/f_audio/audio_enable)\" = 0",
                    timeout: 8
                )
                if result.status == 0 { return }
                cleanupFailure = result.output
            } catch {
                cleanupFailure = error.localizedDescription
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw RuntimeError.moduleCommand(
            cleanupFailure?.isEmpty == false
                ? cleanupFailure!
                : L10n.tr("D4 helper 已退出，但 T/T/B 路由回滚未确认。")
        )
    }

    func stopBridge() throws {
        var failures: [String] = []
        let helperPath = "\(remoteDirectory)/\(manifest.helper)"
        let command = "helper_stopped=1; " +
            "is_owned() { " +
            "current_start=$(awk '{print $22}' \"/proc/$pid/stat\" 2>/dev/null); " +
            "argv0=$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p'); " +
            "test \"$current_start\" = \"$expected_start\" && " +
            "test \"$argv0\" = '\(helperPath)'; }; " +
            "if test -s '\(pidFile)'; then " +
            "read pid expected_start < '\(pidFile)' || true; " +
            "if test -z \"$expected_start\"; then " +
            "expected_start=$(awk '{print $22}' \"/proc/$pid/stat\" 2>/dev/null); " +
            "argv0=$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p'); " +
            "test \"$argv0\" = '\(helperPath)' || expected_start=; fi; " +
            "case \"$pid:$expected_start\" in :*|*:|*[!0-9:]*) true;; *) " +
            "if is_owned; then " +
            "kill -TERM \"$pid\" 2>/dev/null || true; " +
            "n=0; while is_owned && test \"$n\" -lt 30; do " +
            "sleep 0.1; n=$((n+1)); done; " +
            "is_owned && helper_stopped=0 || true; fi;; esac; fi; " +
            "rm -f '\(pidFile)'; test \"$helper_stopped\" -eq 1"
        do {
            let result = try controller.shellChecked(command, timeout: 10)
            if result.status != 0 {
                failures.append(
                    result.output.isEmpty ? L10n.tr("无法停止模块 PCM 桥。") : result.output
                )
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        do { try stopRouteOnly() } catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty {
            throw RuntimeError.moduleCommand(failures.joined(separator: "\n"))
        }
    }

    func bridgeLog() throws -> String {
        let result = try controller.shellChecked(
            "test ! -f '\(logFile)' || tail -n 80 '\(logFile)'; " +
                "test ! -f '\(routeLogFile)' || tail -n 120 '\(routeLogFile)'",
            timeout: 8
        )
        return result.output
    }

    private func routeLog() throws -> String {
        let result = try controller.shellChecked(
            "test ! -f '\(routeLogFile)' || tail -n 160 '\(routeLogFile)'",
            timeout: 8
        )
        return result.output
    }

    private func voiceRouteIsReady() throws -> Bool {
        let helperPath = "\(remoteDirectory)/\(manifest.helper)"
        let command = "test -s '\(routePIDFile)' && " +
            "read pid expected_start < '\(routePIDFile)' && " +
            "test \"$(cut -d ' ' -f 22 \"/proc/$pid/stat\" 2>/dev/null)\" = \"$expected_start\" && " +
            "test \"$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p')\" = '\(helperPath)' && " +
            "tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | grep -q '^--voice-route-session$' && " +
            "grep -q 'VoLTE route session active on hw:0,4' '\(routeLogFile)' && " +
            "test \"$(cat /sys/class/android_usb/f_audio/audio_enable)\" = 1 && " +
            "grep -q '^state: RUNNING' /proc/asound/card0/pcm4p/sub0/status && " +
            "grep -q '^state: RUNNING' /proc/asound/card0/pcm4c/sub0/status"
        return try controller.shellChecked(command, timeout: 8).status == 0
    }

    private func voiceRouteIsStopped() throws -> Bool {
        let helperPath = "\(remoteDirectory)/\(manifest.helper)"
        let command = "owned=0; if test -s '\(routePIDFile)'; then " +
            "read pid expected_start < '\(routePIDFile)' || true; " +
            "current_start=$(cut -d ' ' -f 22 \"/proc/$pid/stat\" 2>/dev/null); " +
            "argv0=$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p'); " +
            "args=$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null); " +
            "if test \"$current_start\" = \"$expected_start\" && " +
            "test \"$argv0\" = '\(helperPath)' && " +
            "printf '%s\\n' \"$args\" | grep -q '^--voice-route-session$'; " +
            "then owned=1; else rm -f '\(routePIDFile)'; fi; fi; " +
            "test \"$owned\" -eq 0"
        return try controller.shellChecked(command, timeout: 8).status == 0
    }

    private func ensureVoiceCalibrationService() throws {
        let command = "owned=0; " +
            "if test -s '\(calibrationPIDFile)'; then " +
            "read pid expected_start < '\(calibrationPIDFile)' || true; " +
            "current_start=$(cut -d ' ' -f 22 \"/proc/$pid/stat\" 2>/dev/null); " +
            "argv0=$(tr '\\000' '\\n' < \"/proc/$pid/cmdline\" 2>/dev/null | sed -n '1p'); " +
            "test \"$current_start\" = \"$expected_start\" && " +
            "test \"$argv0\" = /usr/bin/alsaucm_test && owned=1 || true; fi; " +
            "if test \"$owned\" -eq 0; then " +
            "for proc in /proc/[0-9]*; do " +
            "test -r \"$proc/cmdline\" || continue; " +
            "argv0=$(tr '\\000' '\\n' < \"$proc/cmdline\" 2>/dev/null | sed -n '1p'); " +
            "test \"$argv0\" = /usr/bin/alsaucm_test || continue; " +
            "oldpid=${proc##*/}; kill -TERM \"$oldpid\" 2>/dev/null || true; " +
            "n=0; while kill -0 \"$oldpid\" 2>/dev/null && test \"$n\" -lt 30; do " +
            "sleep 0.1; n=$((n+1)); done; " +
            "kill -0 \"$oldpid\" 2>/dev/null && exit 71 || true; done; " +
            "rm -f /run/alsaucm_test '\(calibrationPIDFile)' '\(calibrationLogFile)'; " +
            "nohup /usr/bin/alsaucm_test </dev/null >> '\(calibrationLogFile)' 2>&1 & pid=$!; " +
            "starttime=$(cut -d ' ' -f 22 \"/proc/$pid/stat\" 2>/dev/null); " +
            "printf '%s %s\\n' \"$pid\" \"$starttime\" > '\(calibrationPIDFile)'; " +
            "n=0; while test \"$n\" -lt 50 && test ! -p /run/alsaucm_test; do " +
            "kill -0 \"$pid\" 2>/dev/null || exit 72; sleep 0.1; n=$((n+1)); done; " +
            "test -p /run/alsaucm_test || exit 73; fi; " +
            "if ! grep -q 'ACDB -> Sent VocProc Cal!' '\(calibrationLogFile)' 2>/dev/null; then " +
            "printf 'open snd_soc_msm_9x07_Tomtom_I2S\\n' > /run/alsaucm_test; " +
            "printf 'set _verb VoLTE\\n' > /run/alsaucm_test; " +
            "printf 'set _enadev Auxpcm Rx\\n' > /run/alsaucm_test; " +
            "printf 'set _enadev Auxpcm Tx\\n' > /run/alsaucm_test; " +
            "n=0; while test \"$n\" -lt 100; do " +
            "grep -q 'ACDB -> Sent VocProc Cal!' '\(calibrationLogFile)' 2>/dev/null && break; " +
            "sleep 0.1; n=$((n+1)); done; fi; " +
            "grep -q 'ACDB -> Sent VocProc Cal!' '\(calibrationLogFile)'"
        let result = try controller.shellChecked(command, timeout: 25)
        guard result.status == 0 else {
            let log = try? controller.shellChecked(
                "test ! -f '\(calibrationLogFile)' || tail -n 100 '\(calibrationLogFile)'",
                timeout: 8
            )
            throw RuntimeError.moduleCommand(
                log?.output.isEmpty == false
                    ? log!.output
                    : (result.output.isEmpty
                        ? L10n.tr("模块 VoLTE ACDB 校准服务没有就绪。")
                        : result.output)
            )
        }
    }

    private func soundDevicesReady() throws -> Bool {
        guard !manifest.requiredDevices.isEmpty else { return false }
        return try controller.shellChecked(soundDeviceChecks, timeout: 8).status == 0
    }

    private func waitForSoundDevices() throws -> Bool {
        guard !manifest.requiredDevices.isEmpty else { return false }
        let command = "ready=0; n=0; while test \"$n\" -lt 100; do " +
            "if \(soundDeviceChecks); then ready=1; break; fi; " +
            "sleep 0.2; n=$((n+1)); done; test \"$ready\" -eq 1"
        return try controller.shellChecked(command, timeout: 25).status == 0
    }

    private var soundDeviceChecks: String {
        (manifest.requiredDevices.map { "test -c '\($0)'" } + [
            "grep -Fq '\(manifest.cardName)' /proc/asound/cards"
        ])
            .joined(separator: " && ")
    }

    private func checked(_ command: String) throws {
        let result = try controller.shellChecked(command)
        guard result.status == 0 else {
            throw RuntimeError.moduleCommand(
                result.output.isEmpty ? L10n.tr("模块命令执行失败。") : result.output
            )
        }
    }

    private func uploadVerified(
        _ data: Data,
        entry: Manifest.FileEntry
    ) throws {
        let finalPath = "\(remoteDirectory)/\(entry.name)"
        let temporaryPath = "\(finalPath).part"
        _ = try? controller.shellChecked("rm -f '\(temporaryPath)'", timeout: 8)
        do {
            try controller.push(
                data,
                to: temporaryPath,
                mode: 0o100000 | entry.mode
            )
            let roundTrip = try controller.pull(
                temporaryPath,
                maximumSize: entry.size
            )
            guard roundTrip == data else {
                throw RuntimeError.moduleCommand(
                    L10n.tr("模块端 %@ 的 ADB 回读校验失败。", entry.name)
                )
            }
            let mode = String(entry.mode, radix: 8)
            let result = try controller.shellChecked(
                "chmod \(mode) '\(temporaryPath)' && " +
                    "mv -f '\(temporaryPath)' '\(finalPath)'",
                timeout: 8
            )
            guard result.status == 0 else {
                throw RuntimeError.moduleCommand(
                    result.output.isEmpty
                        ? L10n.tr("无法原子安装模块端组件 %@。", entry.name)
                        : result.output
                )
            }
        } catch {
            _ = try? controller.shellChecked("rm -f '\(temporaryPath)'", timeout: 8)
            throw error
        }
    }

    private func removeRemoteComponent(_ name: String) throws {
        let result = try controller.shellChecked(
            "rm -f '\(remoteDirectory)/\(name)' '\(remoteDirectory)/\(name).part'",
            timeout: 8
        )
        guard result.status == 0 else {
            throw RuntimeError.moduleCommand(
                result.output.isEmpty
                    ? L10n.tr("无法删除模块端临时组件 %@。", name)
                    : result.output
            )
        }
    }

    private func removeRemoteKernelModuleFiles() throws {
        for module in manifest.modules {
            try removeRemoteComponent(module.file)
        }
    }

    private func unloadModulesLoadedHere(
        _ modules: [Manifest.KernelModule]
    ) -> String? {
        var failures: [String] = []
        for module in modules.reversed() {
            if module.name == "qdc507_voice" || module.name == "qdc507_aprv3" {
                // Once APR/voice callbacks have existed, hot-unloading can race
                // a late DSP callback. Keep the bundle resident until the
                // module itself reboots, even when a later prepare step fails.
                continue
            }
            do {
                if module.name == "qdc507_afe" {
                    let unbind = try controller.shellChecked(
                        "driver=/sys/bus/platform/drivers/qdc507-afe-card; " +
                            "if test -d \"$driver\"; then " +
                            "for entry in \"$driver\"/*; do " +
                            "test -L \"$entry\" || continue; " +
                            "device=${entry##*/}; " +
                            "printf '%s\\n' \"$device\" > \"$driver/unbind\" || exit $?; " +
                            "done; left=0; for entry in \"$driver\"/*; do " +
                            "test -L \"$entry\" && left=1; done; test \"$left\" -eq 0; fi",
                        timeout: 12
                    )
                    if unbind.status != 0 {
                        failures.append(
                            unbind.output.isEmpty
                                ? L10n.tr("无法解绑 QDC507 ASoC 声卡")
                                : L10n.tr("qdc507_afe 声卡解绑：%@", unbind.output)
                        )
                        continue
                    }
                }
                let result = try controller.shellChecked(
                    "rmmod '\(module.name)'",
                    timeout: 12
                )
                if result.status != 0 {
                    failures.append(
                        result.output.isEmpty
                            ? L10n.tr("无法卸载 %@", module.name)
                            : L10n.tr("%@：%@", module.name, result.output)
                    )
                }
            } catch {
                failures.append(
                    L10n.tr("%@：%@", module.name, error.localizedDescription)
                )
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "；")
    }

    private static func locateResourceSource() -> ResourceSource? {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["CELLDOCK_MODULE_VOICE_RESOURCES"] {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("manifest.json").path
            ) {
                return .directory(url)
            }
        }
#endif
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(
            ModuleVoicePayload.fileName
        ), FileManager.default.isReadableFile(atPath: bundled.path) {
            return .payload(bundled)
        }
#if DEBUG
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ModuleVoice", isDirectory: true)
        if FileManager.default.fileExists(
            atPath: sourceTree.appendingPathComponent("manifest.json").path
        ) {
            return .directory(sourceTree)
        }
#endif
        return nil
    }

    private static func loadPackage(
        from source: ResourceSource
    ) throws -> ModuleVoicePayload.Package {
        switch source {
        case let .payload(url):
            return try ModuleVoicePayload.loadPayload(at: url)
#if DEBUG
        case let .directory(url):
            return try ModuleVoicePayload.loadDirectory(at: url)
#endif
        }
    }
}
