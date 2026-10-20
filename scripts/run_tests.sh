#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/caches/clang" "$ROOT/.build/caches/swiftpm"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/caches/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/caches/swiftpm}"
mkdir -p "$ROOT/.build/self-tests"

swiftc \
  -swift-version 5 -parse-as-library \
  "$ROOT/Sources/CellDock/AppLanguage.swift" \
  "$ROOT/Sources/CellDock/CellularModuleID.swift" \
  "$ROOT/Sources/CellDock/CallModels.swift" \
  "$ROOT/Sources/CellDock/CallATParser.swift" \
  "$ROOT/Sources/CellDock/Models.swift" \
  "$ROOT/Sources/CellDock/NetworkThroughput.swift" \
  "$ROOT/Sources/CellDock/PhoneNumberNormalizer.swift" \
  "$ROOT/Sources/CellDock/CarrierNameFormatter.swift" \
  "$ROOT/Sources/CellDockNetworkIPC/CellDockNetworkIPC.swift" \
  "$ROOT/Sources/CellDock/ATResponseParser.swift" \
  "$ROOT/Sources/CellDock/SMSVerificationCode.swift" \
  "$ROOT/Sources/CellDock/SMSPDUDecoder.swift" \
  "$ROOT/Sources/CellDock/LocalCallAPIProtocol.swift" \
  "$ROOT/Sources/CellDock/LocalCallAPIServer.swift" \
  "$ROOT/Sources/CellDock/AppTerminationCoordinator.swift" \
  "$ROOT/Tests/LocalCallAPISelfTests/LifecycleTests.swift" \
  "$ROOT/Tests/LocalCallAPISelfTests/main.swift" \
  -o "$ROOT/.build/self-tests/LocalCallAPISelfTests"
"$ROOT/.build/self-tests/LocalCallAPISelfTests"

for language in zh-Hans en ja fr; do
  localization_dir="$ROOT/Resources/Localization/$language.lproj"
  plutil -lint "$localization_dir/Localizable.strings" >/dev/null
  plutil -lint "$localization_dir/InfoPlist.strings" >/dev/null
done
"$ROOT/scripts/check_localizations.py"

xcrun swift "$ROOT/scripts/build_module_voice_payload.swift" \
  "$ROOT/Resources/ModuleVoice" \
  "$ROOT/.build/self-tests/ModuleVoice.payload" >/dev/null
xcrun swift "$ROOT/scripts/build_module_voice_payload.swift" \
  "$ROOT/Resources/ModuleVoice" \
  "$ROOT/.build/self-tests/ModuleVoice.second.payload" >/dev/null
cmp \
  "$ROOT/.build/self-tests/ModuleVoice.payload" \
  "$ROOT/.build/self-tests/ModuleVoice.second.payload"

swiftc \
  -swift-version 5 \
  "$ROOT/Sources/CellDock/AppLanguage.swift" \
  "$ROOT/Sources/CellDock/AppIdentityMigration.swift" \
  "$ROOT/Sources/CellDock/CellularModuleID.swift" \
  "$ROOT/Sources/CellDock/CallModels.swift" \
  "$ROOT/Sources/CellDock/CallHistoryStore.swift" \
  "$ROOT/Sources/CellDock/CallToneSynthesizer.swift" \
  "$ROOT/Sources/CellDock/PhoneNumberNormalizer.swift" \
  "$ROOT/Sources/CellDock/PrivacyPresentation.swift" \
  "$ROOT/Sources/CellDock/CallATParser.swift" \
  "$ROOT/Sources/CellDock/ATConsoleModels.swift" \
  "$ROOT/Sources/CellDock/VoiceSignalProcessor.swift" \
  "$ROOT/Sources/CellDock/CarrierNameFormatter.swift" \
  "$ROOT/Sources/CellDock/NotificationRouting.swift" \
  "$ROOT/Sources/CellDock/LaunchAtLoginController.swift" \
  "$ROOT/Sources/CellDock/ADBProtocol.swift" \
  "$ROOT/Sources/CellDock/ModuleVoicePayload.swift" \
  "$ROOT/Sources/CellDockNetworkIPC/CellDockNetworkIPC.swift" \
  "$ROOT/Sources/CellDockNetworkHelper/NetworkHelperState.swift" \
  "$ROOT/Sources/CellDock/Models.swift" \
  "$ROOT/Sources/CellDock/QADBKeyDeriver.swift" \
  "$ROOT/Sources/CellDock/MessageConversation.swift" \
  "$ROOT/Sources/CellDock/CellularLinkRecovery.swift" \
  "$ROOT/Sources/CellDock/CellularModuleModels.swift" \
  "$ROOT/Sources/CellDock/NetworkThroughput.swift" \
  "$ROOT/Sources/CellDock/DeletedMessageRegistry.swift" \
  "$ROOT/Sources/CellDock/EUICCModels.swift" \
  "$ROOT/Sources/CellDock/ATResponseParser.swift" \
  "$ROOT/Sources/CellDock/SMSPDUDecoder.swift" \
  "$ROOT/Sources/CellDock/SMSPDUEncoder.swift" \
  "$ROOT/Sources/CellDock/SMSVerificationCode.swift" \
  "$ROOT/Sources/CellDock/SOCKSProtocol.swift" \
  "$ROOT/Sources/CellDock/BoundSocket.swift" \
  "$ROOT/Sources/CellDock/SOCKSDNSResolver.swift" \
  "$ROOT/Sources/CellDock/SOCKSProxyModels.swift" \
  "$ROOT/Sources/CellDock/VoWiFiRuntimeModels.swift" \
  "$ROOT/Sources/CellDock/VoWiFiRuntimeControl.swift" \
  "$ROOT/Sources/CellDock/VoWiFiUpstreamProxyModels.swift" \
  "$ROOT/Sources/CellDock/VerificationMessageAutoDelete.swift" \
  "$ROOT/Tests/SelfTests/main.swift" \
  -o "$ROOT/.build/self-tests/CellDockSelfTests"

"$ROOT/.build/self-tests/CellDockSelfTests"

swiftc \
  -swift-version 5 \
  "$ROOT/Sources/CellDock/SMSVerificationCode.swift" \
  "$ROOT/Sources/CellDock/SMSContentDetector.swift" \
  "$ROOT/Tests/SMSContentSelfTests/main.swift" \
  -o "$ROOT/.build/self-tests/SMSContentSelfTests"

"$ROOT/.build/self-tests/SMSContentSelfTests"

swiftc \
  -swift-version 5 \
  "$ROOT/Sources/CellDock/AppLanguage.swift" \
  "$ROOT/Sources/CellDock/AppIdentityMigration.swift" \
  "$ROOT/Sources/CellDock/CellularModuleID.swift" \
  "$ROOT/Sources/CellDock/CallModels.swift" \
  "$ROOT/Sources/CellDock/CallRecordingStore.swift" \
  "$ROOT/Sources/CellDock/CallRecordingWaveform.swift" \
  "$ROOT/Tests/CallRecordingSelfTests/main.swift" \
  -framework AppKit \
  -framework AudioToolbox \
  -framework AVFoundation \
  -framework UniformTypeIdentifiers \
  -o "$ROOT/.build/self-tests/CallRecordingSelfTests"

"$ROOT/.build/self-tests/CallRecordingSelfTests"

swiftc \
  -swift-version 5 \
  "$ROOT/Sources/CellDock/AppLanguage.swift" \
  "$ROOT/Sources/CellDock/PhoneNumberNormalizer.swift" \
  "$ROOT/Sources/CellDock/SystemContactStore.swift" \
  "$ROOT/Tests/ContactStoreSelfTests/main.swift" \
  -framework AppKit \
  -framework Contacts \
  -o "$ROOT/.build/self-tests/ContactStoreSelfTests"

"$ROOT/.build/self-tests/ContactStoreSelfTests"

swiftc \
  -swift-version 5 \
  "$ROOT/Sources/CellDock/SMSForwardingSigning.swift" \
  "$ROOT/Tests/SMSForwardingSelfTests/main.swift" \
  -o "$ROOT/.build/self-tests/SMSForwardingSelfTests"

"$ROOT/.build/self-tests/SMSForwardingSelfTests"

xcrun clang \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -I "$ROOT/Sources/CUACProbe/include" \
  "$ROOT/Tests/CUACProbeSelfTests.c" \
  -framework CoreAudio \
  -framework CoreFoundation \
  -framework IOKit \
  -o "$ROOT/.build/self-tests/CUACProbeSelfTests"

"$ROOT/.build/self-tests/CUACProbeSelfTests"

xcrun clang \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -I "$ROOT/Sources/CModemBridge/include" \
  "$ROOT/Sources/CModemBridge/ModemBridge.c" \
  "$ROOT/Tests/CModemBridgeSelfTests.c" \
  -framework CoreFoundation \
  -framework IOKit \
  -o "$ROOT/.build/self-tests/CModemBridgeSelfTests"

"$ROOT/.build/self-tests/CModemBridgeSelfTests"

EUICC_SOURCES=(
  "$ROOT/Sources/CEuiccCore/CellDockEUICCBridge.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/cjson/cJSON.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/cjson/cJSON_ex.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/base64.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/derutil.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/es8p.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/es9p.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/es9p_errors.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/es10a.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/es10b.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/es10c.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/es10c_ex.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/euicc.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/hexutil.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/interface.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/sha256.c"
  "$ROOT/Sources/CEuiccCore/Vendor/lpac/euicc/tostr.c"
)

xcrun clang \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-sign-compare \
  -Wno-shorten-64-to-32 \
  -Wno-unused-parameter \
  -I "$ROOT/Sources/CEuiccCore/include" \
  -I "$ROOT/Sources/CEuiccCore/Vendor/lpac" \
  "${EUICC_SOURCES[@]}" \
  "$ROOT/Tests/CEuiccCoreSelfTests.c" \
  -o "$ROOT/.build/self-tests/CEuiccCoreSelfTests"

"$ROOT/.build/self-tests/CEuiccCoreSelfTests"
