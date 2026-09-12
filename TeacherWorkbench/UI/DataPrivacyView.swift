import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DataPrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    let portabilityService: DataPortabilityService
    let onDataChanged: () -> Void

    init(
        portabilityService: DataPortabilityService,
        onDataChanged: @escaping () -> Void = {}
    ) {
        self.portabilityService = portabilityService
        self.onDataChanged = onDataChanged
    }

    @AppStorage("lastBackupAt") private var lastBackupAt: Double = 0
    @AppStorage("backupReminderEnabled") private var backupReminderEnabled = false

    @State private var exportFormat: ExportFormat = .csv
    @State private var isShowingBackupPassword = false
    @State private var isShowingRestorePassword = false
    @State private var isShowingRestoreImporter = false
    @State private var isShowingExportWarning = false
    @State private var isShowingBackupShareSheet = false
    @State private var isShowingExportExporter = false
    @State private var pendingRestoreURL: URL?
    @State private var pendingExportModules: Set<DataModule>?
    @State private var backupExportURL: URL?
    @State private var exportDocument: PortabilityFileDocument?
    @State private var exportContentType: UTType = .data
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var pendingBackupPassword: String?
    @State private var pendingRestorePassword: String?
    @State private var pendingPasswordError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("SQLCipher 加密", systemImage: "lock.shield.fill")
                    LabeledContent("云同步") {
                        Text("关闭")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("本地数据库")
                } footer: {
                    Text("数据库密钥只保存在本机 Keychain；应用目录已设置为不参与自动云备份。")
                }

                Section {
                    Button {
                        isShowingBackupPassword = true
                    } label: {
                        Label("创建加密备份", systemImage: "externaldrive.badge.plus")
                    }
                    .accessibilityIdentifier("create-backup-button")

                    Button {
                        isShowingRestoreImporter = true
                    } label: {
                        Label("从备份恢复", systemImage: "arrow.down.doc")
                    }
                    .accessibilityIdentifier("restore-backup-button")

                    LabeledContent("最近备份") {
                        Text(lastBackupAt == 0 ? "尚未创建" : formattedDate(Date(timeIntervalSince1970: lastBackupAt)))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("恢复备份")
                } footer: {
                    Text("备份包含完整的 ClassVault 数据，使用独立密码加密。恢复前会验证备份并保留当前数据库的安全副本。")
                }

                Section {
                    Picker("文件格式", selection: $exportFormat) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }

                    Button {
                        pendingExportModules = [.students]
                        isShowingExportWarning = true
                    } label: {
                        Label("导出学生信息", systemImage: "person.text.rectangle")
                    }

                    Button {
                        pendingExportModules = [.contacts]
                        isShowingExportWarning = true
                    } label: {
                        Label("导出联系人信息", systemImage: "person.crop.circle")
                    }

                    Button {
                        pendingExportModules = [.students, .contacts]
                        isShowingExportWarning = true
                    } label: {
                        Label("导出完整数据集", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("export-complete-dataset-button")
                } header: {
                    Text("数据导出")
                } footer: {
                    Text("CSV、XLSX 和 JSON 导出面向 Excel 或其他软件使用，可能包含可读的学生隐私信息；不会包含数据库密钥、迁移记录或内部变更历史。")
                }

                Section("隐私") {
                    Toggle("备份提醒", isOn: $backupReminderEnabled)
                    Label("Face ID / 设备密码", systemImage: "faceid")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("数据与隐私")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isShowingRestoreImporter,
                allowedContentTypes: [ClassVaultFileTypes.backup],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else {
                    if case .failure = result { errorMessage = "备份文件无法读取。" }
                    return
                }
                pendingRestoreURL = url
                isShowingRestorePassword = true
            }
            .fileExporter(
                isPresented: $isShowingExportExporter,
                document: exportDocument,
                contentTypes: [exportContentType],
                defaultFilename: "ClassVault-\(filenameDate()).\(exportFormat.fileExtension)"
            ) { result in
                if case .failure(let error) = result {
                    errorMessage = "数据导出未保存。\n\(error.localizedDescription)"
                }
                exportDocument = nil
            }
            .sheet(
                isPresented: $isShowingBackupShareSheet,
                onDismiss: finishBackupShareSheet
            ) {
                if let backupExportURL {
                    BackupShareSheet(fileURL: backupExportURL) { completed, error in
                        Task { @MainActor in
                            if completed {
                                lastBackupAt = Date().timeIntervalSince1970
                            } else if let error {
                                errorMessage = "加密备份未保存。\n\(error.localizedDescription)"
                            }
                            isShowingBackupShareSheet = false
                        }
                    }
                }
            }
            .sheet(
                isPresented: $isShowingBackupPassword,
                onDismiss: finishBackupPasswordEntry
            ) {
                PasswordEntryView(
                    title: "创建加密备份",
                    message: "备份密码不会保存到 ClassVault。请使用你能记住的密码。",
                    actionTitle: "继续",
                    onSubmit: submitBackupPassword
                )
                .presentationDetents([.medium])
            }
            .sheet(
                isPresented: $isShowingRestorePassword,
                onDismiss: finishRestorePasswordEntry
            ) {
                PasswordEntryView(
                    title: "验证并恢复备份",
                    message: "输入备份创建时设置的密码。验证失败不会修改当前数据库。",
                    actionTitle: "恢复并替换",
                    onSubmit: submitRestorePassword
                )
                .presentationDetents([.medium])
            }
            .confirmationDialog(
                "导出前请确认隐私风险",
                isPresented: $isShowingExportWarning,
                titleVisibility: .visible
            ) {
                Button("继续导出") { prepareExport() }
                Button("取消", role: .cancel) { pendingExportModules = nil }
            } message: {
                Text("\(exportFormat.displayName) 文件通常是可读的明文文件。请仅保存到你信任的位置，并在不需要时删除。")
            }
            .alert("数据与隐私", isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )) {
                Button("确定", role: .cancel) { statusMessage = nil }
            } message: {
                Text(statusMessage ?? "操作已完成。")
            }
            .alert("操作失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "请求的操作无法完成。")
            }
        }
    }

    private func submitBackupPassword(_ password: String) {
        guard password.count >= 8 else {
            pendingPasswordError = BackupError.passwordTooShort.localizedDescription
            isShowingBackupPassword = false
            return
        }
        pendingBackupPassword = password
        isShowingBackupPassword = false
    }

    private func finishBackupPasswordEntry() {
        if let pendingPasswordError {
            self.pendingPasswordError = nil
            errorMessage = pendingPasswordError
            return
        }
        guard let password = pendingBackupPassword else { return }
        pendingBackupPassword = nil
        Task { @MainActor in
            await Task.yield()
            prepareBackup(password: password)
        }
    }

    private func prepareBackup(password: String) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassVault-\(filenameDate()).classvaultbackup")
        do {
            _ = try portabilityService.backup.createBackup(destination: tempURL, password: password)
            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                throw BackupError.validationFailed
            }
            backupExportURL = tempURL
            Task { @MainActor in
                await Task.yield()
                isShowingBackupShareSheet = true
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            errorMessage = "加密备份创建失败。\n\(error.localizedDescription)"
        }
    }

    private func finishBackupShareSheet() {
        if let backupExportURL {
            try? FileManager.default.removeItem(at: backupExportURL)
        }
        backupExportURL = nil
    }

    private func submitRestorePassword(_ password: String) {
        guard password.count >= 8 else {
            pendingPasswordError = BackupError.passwordTooShort.localizedDescription
            isShowingRestorePassword = false
            return
        }
        pendingRestorePassword = password
        isShowingRestorePassword = false
    }

    private func finishRestorePasswordEntry() {
        if let pendingPasswordError {
            self.pendingPasswordError = nil
            errorMessage = pendingPasswordError
            return
        }
        guard let password = pendingRestorePassword else { return }
        pendingRestorePassword = nil
        Task { @MainActor in
            await Task.yield()
            restoreBackup(password: password)
        }
    }

    private func restoreBackup(password: String) {
        guard let pendingRestoreURL else { return }
        let didStartSecurityScope = pendingRestoreURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                pendingRestoreURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let result = try portabilityService.backup.restoreBackup(
                from: pendingRestoreURL,
                password: password,
                mode: .replaceCurrentData
            )
            self.pendingRestoreURL = nil
            onDataChanged()
            statusMessage = result.unknownComponents.isEmpty
                ? "备份已验证并恢复。当前数据库的安全副本已保留。"
                : "备份已恢复。发现未识别组件：\(result.unknownComponents.joined(separator: "、"))；这些组件仍保留在原备份文件中，当前版本不会读取它们。"
        } catch {
            errorMessage = "备份未恢复。\n\(error.localizedDescription)"
        }
    }

    private func prepareExport() {
        guard let modules = pendingExportModules else { return }
        pendingExportModules = nil
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClassVault-\(UUID().uuidString).\(exportFormat.fileExtension)")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            _ = try portabilityService.export.exportDataset(
                request: DatasetExportRequest(
                    modules: modules,
                    format: exportFormat
                ),
                destination: tempURL
            )
            exportDocument = try PortabilityFileDocument(data: Data(contentsOf: tempURL))
            exportContentType = contentType(for: exportFormat)
            isShowingExportExporter = true
        } catch {
            errorMessage = "数据导出失败。\n\(error.localizedDescription)"
        }
    }

    private func contentType(for format: ExportFormat) -> UTType {
        switch format {
        case .csv: .commaSeparatedText
        case .xlsx: .spreadsheet
        case .json: .json
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-Hans")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func filenameDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
}

/// Uses the native share sheet so the user can choose “Save to Files”. This
/// keeps the temporary backup URL alive until the system has finished copying
/// it, avoiding the SwiftUI fileExporter/LaunchServices hand-off that could
/// stall before its completion callback.
private struct BackupShareSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let onComplete: (Bool, Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, error in
            onComplete(completed, error)
        }

        if let popover = controller.popoverPresentationController {
            controller.loadViewIfNeeded()
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: controller.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct PasswordEntryView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let message: String
    let actionTitle: String
    let minimumLength: Int = 8
    let onSubmit: (String) -> Void

    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("备份密码", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("密码至少需要 \(minimumLength) 个字符。\n\(message)")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        dismiss()
                        onSubmit(password)
                    }
                    .bold()
                    .disabled(password.count < minimumLength)
                    .accessibilityHint("密码至少需要 \(minimumLength) 个字符")
                }
            }
        }
    }
}

private struct PortabilityFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.data, .commaSeparatedText, .spreadsheet, .json, ClassVaultFileTypes.backup]
    }

    static var writableContentTypes: [UTType] {
        [ClassVaultFileTypes.backup, .commaSeparatedText, .spreadsheet, .json]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
