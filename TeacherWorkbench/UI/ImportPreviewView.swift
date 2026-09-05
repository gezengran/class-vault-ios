import SwiftUI

struct ImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workingPreview: ImportPreview
    @State private var strictMatching: Bool
    @State private var isShowingConfirmation = false
    @State private var mappingError: String?

    let repository: StudentRepository
    let onConfirm: (ImportPreview) -> Void

    init(
        preview: ImportPreview,
        repository: StudentRepository,
        onConfirm: @escaping (ImportPreview) -> Void
    ) {
        _workingPreview = State(initialValue: preview)
        _strictMatching = State(initialValue: preview.strictMatching)
        self.repository = repository
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fileSummary
                    mappingCard
                    sampleCard
                    validationCard
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("导入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { isShowingConfirmation = true }
                        .bold()
                        .disabled(!workingPreview.canCommit)
                        .accessibilityIdentifier("confirm-import-button")
                }
            }
            .confirmationDialog(
                "确认写入本地加密数据库？",
                isPresented: $isShowingConfirmation,
                titleVisibility: .visible
            ) {
                Button("导入 \(workingPreview.acceptedRows.count) 行") {
                    onConfirm(workingPreview)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("现有记录会安全匹配；表格中缺少的记录不会被自动删除。")
            }
            .alert("预览更新失败", isPresented: Binding(
                get: { mappingError != nil },
                set: { if !$0 { mappingError = nil } }
            )) {
                Button("确定", role: .cancel) { mappingError = nil }
            } message: {
                Text(mappingError ?? "字段映射无法更新。")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var fileSummary: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "tablecells.fill")
                        .font(.title2)
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(workingPreview.document.sourceFilename ?? "未命名文件")
                            .font(.headline.weight(.bold))
                            .lineLimit(2)
                        Text("表头位于第 \(workingPreview.document.headerRowNumber) 行")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let tableTitle = workingPreview.document.tableTitle {
                    Label(tableTitle, systemImage: "textformat")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let currentClassName = workingPreview.document.currentClassName,
                   workingPreview.mapping.sourceColumns(for: .className).isEmpty {
                    Label("将把“\(currentClassName)”写入所有学生的当前班级", systemImage: "person.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else if workingPreview.mapping.sourceColumns(for: .className).isEmpty {
                    Label("未识别到当前班级；可在导入后手动补录", systemImage: "person.2.slash")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.warning)
                }

                HStack(spacing: 10) {
                    PreviewMetric(title: "数据行", value: "\(workingPreview.document.rows.count)", color: AppTheme.accent)
                    PreviewMetric(title: "可导入", value: "\(workingPreview.acceptedRows.count)", color: AppTheme.success)
                    PreviewMetric(title: "待复核", value: "\(workingPreview.rejectedRowCount)", color: AppTheme.warning)
                }

                Toggle("严格学号匹配", isOn: $strictMatching)
                    .onChange(of: strictMatching) { _, newValue in
                        rebuildPreview(strictMatching: newValue)
                    }

                Text("关闭时允许使用姓名 + 班级进行无歧义匹配；开启后每一行都必须有学号。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var mappingCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading("字段映射", subtitle: "已自动识别常见中文表头，请在导入前确认。")

                VStack(spacing: 0) {
                    ForEach(Array(workingPreview.document.headers.enumerated()), id: \.offset) { index, header in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(header.isEmpty ? "未命名列" : header)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                Text(mappedFieldName(for: header))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            Picker("字段", selection: mappingSelection(for: header)) {
                                Text("忽略").tag("")
                                ForEach(CanonicalImportField.allCases) { field in
                                    Text(field.displayName).tag(field.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        .padding(.vertical, 10)

                        if index < workingPreview.document.headers.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var sampleCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading("数据预览", subtitle: "显示前五行，确认姓名、学号和联系方式位置。")

                if workingPreview.document.sampleRows.isEmpty {
                    Text("没有可预览的数据行。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(workingPreview.document.sampleRows.enumerated()), id: \.offset) { index, row in
                            SampleRowView(
                                rowNumber: workingPreview.document.headerRowNumber + index + 1,
                                headers: workingPreview.document.headers,
                                values: row
                            )
                        }
                    }
                }
            }
        }
    }

    private var validationCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading("导入校验")

                if workingPreview.issues.isEmpty {
                    Label("校验通过，可以导入", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.success)
                        .font(.headline)
                } else {
                    ForEach(workingPreview.issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: issue.isBlocking ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(issue.isBlocking ? AppTheme.warning : AppTheme.accent)
                            Text(issueText(issue))
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !workingPreview.canCommit {
                    Label("存在阻塞问题，修正字段映射或数据后才能导入。", systemImage: "xmark.circle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func mappingSelection(for header: String) -> Binding<String> {
        Binding(
            get: { workingPreview.mapping.field(for: header)?.rawValue ?? "" },
            set: { rawValue in
                var mapping = workingPreview.mapping
                let field = CanonicalImportField(rawValue: rawValue)
                mapping.set(field, for: header)
                rebuildPreview(mapping: mapping, strictMatching: strictMatching)
            }
        )
    }

    private func mappedFieldName(for header: String) -> String {
        workingPreview.mapping.field(for: header)?.displayName ?? "未映射，将被忽略"
    }

    private func rebuildPreview(mapping: ImportMapping? = nil, strictMatching: Bool) {
        do {
            workingPreview = try repository.rebuildImportPreview(
                workingPreview,
                mapping: mapping ?? workingPreview.mapping,
                strictMatching: strictMatching
            )
        } catch {
            mappingError = "本地数据库无法检查此导入。"
        }
    }

    private func issueText(_ issue: ImportIssue) -> String {
        if let rowNumber = issue.rowNumber {
            return "第 \(rowNumber) 行：\(issue.message)"
        }
        return issue.message
    }
}

private struct PreviewMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct SampleRowView: View {
    let rowNumber: Int
    let headers: [String]
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("第 \(rowNumber) 行")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.accent)

            ForEach(Array(headers.indices), id: \.self) { index in
                let value = values.indices.contains(index) ? values[index] : ""
                if ValueNormalizer.optionalText(value) != nil {
                    HStack(alignment: .top, spacing: 10) {
                        Text(headers[index].isEmpty ? "未命名列" : headers[index])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        Text(value)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(12)
        .background(AppTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
