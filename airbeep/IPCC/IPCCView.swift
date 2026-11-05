import Combine
import SwiftUI

@MainActor
final class IPCCViewModel: ObservableObject {
    static let shared = IPCCViewModel()

    @Published var selectedCarrierID: String = IPCCCarrierCatalog.all.first?.id ?? "46000"
    @Published private(set) var isBusy = false
    @Published private(set) var log: [String] = []
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private var pump: Task<Void, Never>?

    var carriers: [IPCCCarrier] { IPCCCarrierCatalog.all }

    var selectedCarrier: IPCCCarrier {
        IPCCCarrierCatalog.carrier(for: selectedCarrierID) ?? IPCCCarrierCatalog.all[0]
    }

    var pairingReady: Bool {
        let path = PairingController.pairingFilePath()
        return FileManager.default.fileExists(atPath: path)
    }

    func run() {
        guard !isBusy else { return }
        let pairing = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairing) else {
            errorMessage = "未找到配对文件，请先在“配对”页完成配对。"
            return
        }

        isBusy = true
        log.removeAll()
        AirBeepLog.shared.clear()
        startPump()
        let carrier = selectedCarrier

        Task {
            do {
                let staged = try await IPCCInstaller.shared.install(carrier: carrier, pairingPath: pairing)
                log.append("已写入 \(IPCCCarrierCatalog.deviceRoot)/\(carrier.bundleName)")
                try await IPCCInstaller.shared.respring(pairingPath: pairing)
                log.append("已发送重启指令")
                try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                successMessage = "\(carrier.displayName) 配置已写入，设备即将重启。重启后到「设置 › 通用 › 关于本机 › 运营商」确认版本为 \(carrier.bundleName)。"
            } catch {
                errorMessage = error.localizedDescription
            }
            flushLog()
            stopPump()
            isBusy = false
        }
    }

    private func startPump() {
        pump = Task { @MainActor in
            while !Task.isCancelled {
                self.flushLog()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func stopPump() {
        pump?.cancel()
        pump = nil
    }

    private func flushLog() {
        let lines = AirBeepLog.shared.drain()
        guard !lines.isEmpty else { return }
        log.append(contentsOf: lines)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}

struct IPCCView: View {
    @StateObject private var model = IPCCViewModel.shared
    @State private var showingSetup = false
    @State private var showingConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("运营商", selection: $model.selectedCarrierID) {
                        ForEach(model.carriers) { carrier in
                            Text("\(carrier.displayName) · \(carrier.id)").tag(carrier.id)
                        }
                    }
                    LabeledContent("目标 Bundle", value: model.selectedCarrier.bundleName)
                    LabeledContent("SupportedSIMs",
                                   value: model.selectedCarrier.supportedSIMs.joined(separator: " / "))
                } header: {
                    Text("步骤一 · 选择配置")
                } footer: {
                    Text("使用内置的 Apple 签名 IPCC 外壳，仅替换 carrier.plist；signatures 与 *.der.pri 保持原样，因此签名继续有效。")
                }

                Section {
                    HStack {
                        Image(systemName: model.pairingReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.pairingReady ? .green : .orange)
                        Text(model.pairingReady ? "配对文件已就绪" : "尚未配对")
                        Spacer()
                        Button("配对") { showingSetup = true }
                            .buttonStyle(.borderless)
                    }
                } header: {
                    Text("步骤二 · 通道")
                }

                Section {
                    Button {
                        showingConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if model.isBusy {
                                ProgressView().padding(.trailing, 8)
                                Text("正在写入…")
                            } else {
                                Label("执行锁定", systemImage: "antenna.radiowaves.left.and.right")
                            }
                            Spacer()
                        }
                    }
                    .disabled(model.isBusy || !model.pairingReady)
                } footer: {
                    Text("写入 /var/mobile/Library/Carrier Bundles/iPhone，随后发送重启指令。过程中请勿退出应用。")
                }

                if !model.log.isEmpty {
                    Section("运行日志") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                }
            }
            .navigationTitle("锁定 IPCC")
            .sheet(isPresented: $showingSetup) { AirBeepAirliftSetupView() }
            .confirmationDialog("确认写入运营商配置？", isPresented: $showingConfirmation, titleVisibility: .visible) {
                Button("执行锁定", role: .destructive) { model.run() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将覆盖 \(model.selectedCarrier.bundleName) 并重启设备。")
            }
            .alert("操作失败", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("好") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert("完成", isPresented: Binding(
                get: { model.successMessage != nil },
                set: { if !$0 { model.successMessage = nil } }
            )) {
                Button("好") { model.successMessage = nil }
            } message: {
                Text(model.successMessage ?? "")
            }
        }
    }
}
