import AirliftFFI
import Foundation
import ZIPFoundation

enum IPCCError: LocalizedError {
    case resourceMissing(String)
    case archiveFailed(String)
    case stagingFailed(String)
    case airliftUnavailable
    case airliftFailed(String)
    case respringFailed(String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let name): return "缺少内置资源：\(name)"
        case .archiveFailed(let reason): return "解包 IPCC 失败：\(reason)"
        case .stagingFailed(let reason): return "准备写入目录失败：\(reason)"
        case .airliftUnavailable: return "当前构建缺少 AirLift 注入能力"
        case .airliftFailed(let reason): return "写入失败：\(reason)"
        case .respringFailed(let reason): return "重启失败：\(reason)"
        }
    }
}

/// Builds a signed carrier-bundle copy locally, then hands the whole folder to
/// airlift's `al_exploit_inject_folder`, which moves it through AirTraffic into
/// the device's `Carrier Bundles/iPhone` directory outside this app's sandbox.
actor IPCCInstaller {
    static let shared = IPCCInstaller()

    private typealias LogCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

    private typealias WriteDirFn = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        LogCallback?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32

    private typealias RespringFn = @convention(c) (
        UnsafePointer<CChar>?,
        LogCallback?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32

    private static func rtlDefaultHandle() -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    /// Version bumped past the stock bundle so CommCenter prefers the Overlay
    /// copy even right after a system update. Signatures cover `*.der.pri`
    /// only, so editing the plists keeps `signatures/` valid.
    private static let forcedBundleVersion = "9999.0"
    private static let forcedBuildVersion = "9999"

    func install(carrier: IPCCCarrier, pairingPath: String) async throws -> URL {
        let staged = try stage(carrier: carrier)
        do {
            try injectFolder(source: staged, carrier: carrier, pairingPath: pairingPath)
            return staged
        } catch {
            throw error
        }
    }

    // MARK: - Staging

    /// Unpacks the signed template, swaps `carrier.plist`, rewrites the bundle
    /// identity, and returns a local folder named after the target bundle.
    func stage(carrier: IPCCCarrier) throws -> URL {
        guard let ipccURL = IPCCCarrierCatalog.resourceURL("O2_Germany", ext: "ipcc", subdirectory: "IPCCData") else {
            throw IPCCError.resourceMissing(IPCCCarrierCatalog.templateIPCC)
        }
        guard let plistURL = IPCCCarrierCatalog.resourceURL(
            carrier.plistName.replacingOccurrences(of: ".plist", with: ""),
            ext: "plist",
            subdirectory: "IPCCData"
        ) else {
            throw IPCCError.resourceMissing(carrier.plistName)
        }

        let fm = FileManager.default
        let workRoot = fm.temporaryDirectory
            .appending(path: "AirIPCC-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: workRoot, withIntermediateDirectories: true)

        // 1. Unpack the signed template.
        do {
            let archive = try Archive(url: ipccURL, accessMode: .read)
            for entry in archive {
                let destination = workRoot.appending(path: entry.path)
                if entry.type == .directory {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    continue
                }
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = try archive.extract(entry, to: destination)
            }
        } catch {
            throw IPCCError.archiveFailed(error.localizedDescription)
        }

        let templateBundle = workRoot
            .appending(path: "Payload", directoryHint: .isDirectory)
            .appending(path: IPCCCarrierCatalog.templateBundle, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: templateBundle.path) else {
            throw IPCCError.archiveFailed("模板内缺少 \(IPCCCarrierCatalog.templateBundle)")
        }

        // 2. Replace carrier.plist wholesale: the bundled payload already
        //    carries the right APN / IMSConfig / SupportedSIMs set.
        let carrierPlist = templateBundle.appending(path: "carrier.plist")
        try? fm.removeItem(at: carrierPlist)
        try fm.copyItem(at: plistURL, to: carrierPlist)

        // 3. Rewrite the bundle identity so CommCenter matches it to the SIM.
        try rewriteIdentity(in: templateBundle, carrier: carrier)

        // 4. Rename to the target bundle name.
        let staged = workRoot.appending(path: carrier.bundleName, directoryHint: .isDirectory)
        try fm.moveItem(at: templateBundle, to: staged)
        return staged
    }

    private func rewriteIdentity(in bundle: URL, carrier: IPCCCarrier) throws {
        let fm = FileManager.default

        let infoURL = bundle.appending(path: "Info.plist")
        var info = try readPlist(at: infoURL)
        info["CFBundleIdentifier"] = carrier.bundleIdentifier
        info["CFBundleName"] = carrier.shortName
        info["CFBundleExecutable"] = carrier.shortName
        info["CFBundleVersion"] = Self.forcedBuildVersion
        info["CFBundleShortVersionString"] = Self.forcedBundleVersion
        try writePlist(info, to: infoURL)

        // version.plist must agree or CommCenter may reject the copy.
        let versionURL = bundle.appending(path: "version.plist")
        if fm.fileExists(atPath: versionURL.path) {
            var version = try readPlist(at: versionURL)
            version["CFBundleVersion"] = Self.forcedBuildVersion
            version["CFBundleShortVersionString"] = Self.forcedBundleVersion
            version["BuildVersion"] = Self.forcedBuildVersion
            try writePlist(version, to: versionURL)
        }
    }

    private func readPlist(at url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any] else {
            throw IPCCError.stagingFailed("无法解析 \(url.lastPathComponent)")
        }
        return dictionary
    }

    private func writePlist(_ dictionary: [String: Any], to url: URL) throws {
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .binary,
                options: 0
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw IPCCError.stagingFailed("无法写入 \(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    // MARK: - Device transfer

    private func injectFolder(source: URL, carrier: IPCCCarrier, pairingPath: String) throws {
        let target = "\(IPCCCarrierCatalog.deviceRoot)/\(carrier.bundleName)"

        // Airlift at commit 40640c4 only ships al_exploit_write_dir (no
        // al_exploit_inject_folder), so the bundle is pushed in two passes:
        // the flat files first, then the signatures subdirectory.
        let flat = try makeFlatCopy(of: source)
        defer { try? FileManager.default.removeItem(at: flat) }
        try writeDirectory(source: flat.path, target: target, pairingPath: pairingPath)

        let signatures = source.appending(path: "signatures", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: signatures.path) {
            try writeDirectory(
                source: signatures.path,
                target: target + "/signatures",
                pairingPath: pairingPath
            )
        }
    }

    /// Copies only the regular files at the bundle root into a scratch folder,
    /// so the first pass does not need to create nested directories on device.
    private func makeFlatCopy(of bundle: URL) throws -> URL {
        let fm = FileManager.default
        let flat = fm.temporaryDirectory
            .appending(path: "AirIPCCFlat-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: flat, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.isDirectoryKey])
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDirectory else { continue }
            try fm.copyItem(at: entry, to: flat.appending(path: entry.lastPathComponent))
        }
        return flat
    }

    private func writeDirectory(source: String, target: String, pairingPath: String) throws {
        guard let symbol = dlsym(Self.rtlDefaultHandle(), "al_exploit_write_dir") else {
            throw IPCCError.airliftUnavailable
        }
        let write = unsafeBitCast(symbol, to: WriteDirFn.self)

        var outputError: UnsafeMutablePointer<CChar>?
        let result = pairingPath.withCString { pairingCString in
            source.withCString { sourceCString in
                target.withCString { targetCString in
                    write(
                        pairingCString,
                        sourceCString,
                        targetCString,
                        AirBeepLog.ffiCallback,
                        nil,
                        &outputError
                    )
                }
            }
        }

        let message = outputError.map { String(cString: $0) }
        if let outputError { al_string_free(outputError) }
        guard result == 0 else {
            throw IPCCError.airliftFailed(message ?? "al_exploit_write_dir 返回 \(result)（目标 \(target)）")
        }
    }

    func respring(pairingPath: String) throws {
        guard let symbol = dlsym(Self.rtlDefaultHandle(), "al_device_respring") else {
            throw IPCCError.airliftUnavailable
        }
        let respring = unsafeBitCast(symbol, to: RespringFn.self)

        var outputError: UnsafeMutablePointer<CChar>?
        let result = pairingPath.withCString { pairingCString in
            respring(pairingCString, AirBeepLog.ffiCallback, nil, &outputError)
        }

        let message = outputError.map { String(cString: $0) }
        if let outputError { al_string_free(outputError) }
        guard result == 0 else {
            throw IPCCError.respringFailed(message ?? "al_device_respring 返回 \(result)")
        }
    }
}
