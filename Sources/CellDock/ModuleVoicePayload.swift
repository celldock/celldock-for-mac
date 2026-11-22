import CryptoKit
import Foundation

struct ModuleVoiceManifest: Codable, Equatable {
    struct FileEntry: Codable, Equatable {
        let name: String
        let mode: UInt32
        let size: Int
        let sha256: String
        let offset: Int?
    }

    struct KernelModule: Codable, Equatable {
        let file: String
        let name: String
    }

    let formatVersion: Int
    let runtimeVersion: String
    let kernelRelease: String
    let cardName: String
    let helper: String
    let files: [FileEntry]
    let modules: [KernelModule]
    let requiredDevices: [String]
}

enum ModuleVoicePayload {
    struct Package {
        let manifest: ModuleVoiceManifest
        let components: [String: Data]
    }

    enum PayloadError: AppLocalizedError {
        case invalid(String)
        case missing(String)

        var errorDescription: String? {
            switch self {
            case let .invalid(message):
                return L10n.tr("QDC507 通话资源包无效：%@", message)
            case let .missing(name):
                return L10n.tr("QDC507 通话资源包缺少组件：%@", name)
            }
        }
    }

    static let fileName = "ModuleVoice.payload"
    static let magic = Data([
        0x4D, 0x41, 0x56, 0x4F, 0x56, 0x4F,
        0x49, 0x43, 0x45, 0x50, 0x4B, 0x47,
    ])
    static let formatVersion: UInt32 = 1
    static let headerSize = 24
    static let maximumPayloadSize = 64 * 1_024 * 1_024
    static let maximumManifestSize = 1 * 1_024 * 1_024

    static func loadPayload(at url: URL) throws -> Package {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let rawSize = attributes[.size] as? NSNumber,
              rawSize.intValue >= headerSize,
              rawSize.intValue <= maximumPayloadSize else {
            throw PayloadError.invalid(L10n.tr("文件大小超出允许范围"))
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == rawSize.intValue,
              data.prefix(magic.count) == magic else {
            throw PayloadError.invalid(L10n.tr("文件头不匹配"))
        }
        guard readUInt32LE(data, at: 12) == formatVersion else {
            throw PayloadError.invalid(L10n.tr("格式版本不受支持"))
        }

        let manifestLength64 = readUInt64LE(data, at: 16)
        guard manifestLength64 <= UInt64(maximumManifestSize),
              manifestLength64 <= UInt64(Int.max) else {
            throw PayloadError.invalid(L10n.tr("清单长度超出允许范围"))
        }
        let manifestLength = Int(manifestLength64)
        guard manifestLength <= data.count - headerSize else {
            throw PayloadError.invalid(L10n.tr("清单数据不完整"))
        }

        let manifestRange = headerSize ..< headerSize + manifestLength
        let manifest: ModuleVoiceManifest
        do {
            manifest = try JSONDecoder().decode(
                ModuleVoiceManifest.self,
                from: data.subdata(in: manifestRange)
            )
        } catch {
            throw PayloadError.invalid(L10n.error("无法解析清单：%@", underlying: error))
        }
        try validate(manifest, requiresOffsets: true)

        let contentStart = manifestRange.upperBound
        let contentLength = data.count - contentStart
        var expectedOffset = 0
        var components: [String: Data] = [:]

        for entry in manifest.files {
            guard let offset = entry.offset,
                  offset == expectedOffset,
                  entry.size <= contentLength - offset else {
                throw PayloadError.invalid(L10n.tr("%@ 的数据范围无效", entry.name))
            }
            let range = contentStart + offset ..< contentStart + offset + entry.size
            let component = data.subdata(in: range)
            try verify(component, entry: entry)
            components[entry.name] = component
            expectedOffset += entry.size
        }
        guard expectedOffset == contentLength else {
            throw PayloadError.invalid(L10n.tr("资源包包含未声明的尾部数据"))
        }
        return Package(manifest: manifest, components: components)
    }

#if DEBUG
    static func loadDirectory(at directory: URL) throws -> Package {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: ModuleVoiceManifest
        do {
            manifest = try JSONDecoder().decode(ModuleVoiceManifest.self, from: manifestData)
        } catch {
            throw PayloadError.invalid(L10n.error("无法解析开发资源清单：%@", underlying: error))
        }
        try validate(manifest, requiresOffsets: false)

        var components: [String: Data] = [:]
        for entry in manifest.files {
            let url = directory.appendingPathComponent(entry.name)
            guard url.deletingLastPathComponent().standardizedFileURL ==
                    directory.standardizedFileURL,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw PayloadError.missing(entry.name)
            }
            let component = try Data(contentsOf: url, options: .mappedIfSafe)
            try verify(component, entry: entry)
            components[entry.name] = component
        }
        return Package(manifest: manifest, components: components)
    }
#endif

    private static func validate(
        _ manifest: ModuleVoiceManifest,
        requiresOffsets: Bool
    ) throws {
        let fileNames = manifest.files.map(\.name)
        let moduleNames = manifest.modules.map(\.name)
        let moduleFiles = manifest.modules.map(\.file)
        let fileNameSet = Set(fileNames)

        guard manifest.formatVersion == 1,
              safeName(manifest.helper),
              !manifest.runtimeVersion.isEmpty,
              safeName(manifest.kernelRelease),
              safeName(manifest.cardName),
              !manifest.files.isEmpty,
              manifest.files.count <= 32,
              fileNameSet.count == fileNames.count,
              manifest.files.allSatisfy({
                  safeName($0.name) &&
                      $0.mode >= 0o400 &&
                      $0.mode <= 0o777 &&
                      $0.size > 0 &&
                      $0.size <= maximumPayloadSize &&
                      isSHA256($0.sha256) &&
                      (!requiresOffsets || $0.offset != nil)
              }),
              Set(moduleNames).count == moduleNames.count,
              Set(moduleFiles).count == moduleFiles.count,
              manifest.modules.allSatisfy({
                  safeName($0.file) &&
                      safeModuleName($0.name) &&
                      fileNameSet.contains($0.file)
              }),
              manifest.requiredDevices.allSatisfy({
                  $0.hasPrefix("/dev/snd/") && !$0.contains("'")
              }) else {
            throw PayloadError.invalid(L10n.tr("字段、文件名或完整性元数据不符合要求"))
        }
        guard fileNameSet.contains(manifest.helper) else {
            throw PayloadError.invalid(L10n.tr("helper 未包含在 files 中"))
        }
    }

    private static func verify(
        _ data: Data,
        entry: ModuleVoiceManifest.FileEntry
    ) throws {
        guard data.count == entry.size else {
            throw PayloadError.invalid(L10n.tr("%@ 的长度不匹配", entry.name))
        }
        let actualHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualHash == entry.sha256 else {
            throw PayloadError.invalid(L10n.tr("%@ 的 SHA-256 不匹配", entry.name))
        }
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { return UInt32.max }
        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= 0, offset <= data.count - 8 else { return UInt64.max }
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isASCII && ($0.isNumber || ("a" ... "f").contains($0))
        }
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
        }
    }

    private static func safeModuleName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
        }
    }
}
