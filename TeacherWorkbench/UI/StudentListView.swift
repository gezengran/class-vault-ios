import SwiftUI
import UniformTypeIdentifiers

struct StudentListView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var viewModel: StudentListViewModel

    let portabilityService: DataPortabilityService

    @State private var isShowingFileImporter = false
    @State private var isShowingImportPreview = false
    @State private var isShowingStudentEditor = false
    @State private var isShowingDataPrivacy = false
    @State private var importPreview: ImportPreview?
    @State private var importResult: ImportResult?
    @State private var pendingArchiveStudent: StudentSummary?
    @State private var errorMessage: String?
    @State private var operationErrorMessage: String?

    init(repository: StudentRepository, portabilityService: DataPortabilityService) {
        _viewModel = StateObject(wrappedValue: StudentListViewModel(repository: repository))
        self.portabilityService = portabilityService
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        listHeader

                        if viewModel.isLoading && viewModel.students.isEmpty {
                            loadingState
                        } else if viewModel.students.isEmpty {
                            emptyState
                        } else {
                            studentList
                        }
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("学生")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $viewModel.searchText, prompt: "搜索姓名或学号")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    classFilter
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isShowingStudentEditor = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("手动新增学生")
                    .accessibilityIdentifier("add-student-button")

                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("导入学生表格")
                    .accessibilityIdentifier("import-button")

                    Button {
                        container.lock()
                    } label: {
                        Image(systemName: "lock.fill")
                    }
                    .accessibilityLabel("锁定")
                    .accessibilityIdentifier("lock-button")

                    Button {
                        isShowingDataPrivacy = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("数据与隐私")
                    .accessibilityIdentifier("data-privacy-button")
                }
            }
            .task { viewModel.load() }
            .onChange(of: viewModel.searchText) { _, _ in viewModel.load() }
            .onChange(of: viewModel.selectedClass) { _, _ in viewModel.load() }
            .refreshable { viewModel.load() }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: supportedImportTypes,
                allowsMultipleSelection: false
            ) { result in
                handleSelectedFile(result)
            }
            .sheet(isPresented: $isShowingImportPreview, onDismiss: {
                importPreview = nil
            }) {
                if let importPreview {
                    ImportPreviewView(
                        preview: importPreview,
                        repository: viewModel.repository,
                        onConfirm: { preview in
                            do {
                                importResult = try viewModel.commitImport(preview)
                                isShowingImportPreview = false
                            } catch {
                                errorMessage = "导入写入本地数据库失败。\n\(error.localizedDescription)"
                            }
                        }
                    )
                }
            }
            .sheet(isPresented: $isShowingStudentEditor) {
                StudentEditorView(
                    repository: viewModel.repository,
                    onSaved: { viewModel.load() }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $isShowingDataPrivacy) {
                DataPrivacyView(portabilityService: portabilityService) {
                    viewModel.load()
                }
            }
            .confirmationDialog(
                "确认删除学生档案？",
                isPresented: Binding(
                    get: { pendingArchiveStudent != nil },
                    set: { if !$0 { pendingArchiveStudent = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除学生", role: .destructive) {
                    if let student = pendingArchiveStudent {
                        do {
                            try viewModel.archiveStudent(student.id)
                        } catch {
                            operationErrorMessage = "学生档案删除失败。\n\(error.localizedDescription)"
                        }
                    }
                    pendingArchiveStudent = nil
                }
                Button("取消", role: .cancel) { pendingArchiveStudent = nil }
            } message: {
                Text("“\(pendingArchiveStudent?.name ?? "该学生")”将从当前列表中移除；本地历史记录仍会保留。")
            }
            .alert(item: $importResult) { result in
                Alert(
                    title: Text("导入完成"),
                    message: Text(importSummary(result)),
                    dismissButton: .default(Text("确定"))
                )
            }
            .alert("无法导入", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "所选文件无法读取。")
            }
            .alert("操作失败", isPresented: Binding(
                get: { operationErrorMessage != nil },
                set: { if !$0 { operationErrorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { operationErrorMessage = nil }
            } message: {
                Text(operationErrorMessage ?? "请求的操作无法完成。")
            }
            .alert("学生数据加载失败", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "请稍后重试。")
            }
        }
    }

    private var listHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("学生档案")
                    .font(.title2.weight(.bold))
            }

            Spacer(minLength: 12)

            if !viewModel.students.isEmpty {
                Text("\(viewModel.students.count) 人")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppTheme.accent.opacity(0.10), in: Capsule())
            }
        }
    }

    private var loadingState: some View {
        AppCard {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在加载学生…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var studentList: some View {
        LazyVStack(spacing: 12) {
            ForEach(viewModel.students) { student in
                HStack(spacing: 8) {
                    NavigationLink {
                        StudentDetailView(repository: viewModel.repository, studentID: student.id)
                    } label: {
                        StudentCardView(student: student)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("student-card-\(student.id)")

                    Menu {
                        Button("删除学生档案", systemImage: "trash", role: .destructive) {
                            pendingArchiveStudent = student
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 44)
                    }
                    .accessibilityLabel("学生操作")
                    .accessibilityIdentifier("student-actions-\(student.id)")
                }
            }
        }
    }

    private var emptyState: some View {
        AppCard {
            VStack(spacing: 18) {
                EmptyStateIllustration(systemImage: viewModel.searchText.isEmpty ? "person.3.fill" : "magnifyingglass")

                VStack(spacing: 7) {
                    Text(viewModel.searchText.isEmpty ? "还没有学生数据" : "没有找到匹配的学生")
                        .font(.title3.weight(.bold))
                    Text(viewModel.searchText.isEmpty
                         ? "导入 CSV 或 XLSX 表格，建立本地学生通讯录。"
                         : "请尝试其他姓名、学号或清除搜索条件。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if viewModel.searchText.isEmpty {
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Label("导入学生表格", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("empty-import-button")

                    Button {
                        isShowingStudentEditor = true
                    } label: {
                        Label("手动新增学生", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("empty-add-student-button")
                } else {
                    Button("清除搜索") {
                        viewModel.searchText = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private var classFilter: some View {
        Menu {
            Button {
                viewModel.selectedClass = ""
            } label: {
                HStack {
                    Text("全部当前班级")
                    if viewModel.selectedClass.isEmpty {
                        Image(systemName: "checkmark")
                    }
                }
            }
            ForEach(viewModel.classNames, id: \.self) { className in
                Button {
                    viewModel.selectedClass = className
                } label: {
                    HStack {
                        Text(className)
                        if viewModel.selectedClass == className {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(viewModel.selectedClass.isEmpty ? "当前班级筛选" : "当前班级：\(viewModel.selectedClass)")
        .disabled(viewModel.classNames.count < 2)
        .accessibilityIdentifier("class-filter")
    }

    private var supportedImportTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .spreadsheet]
        if let xlsx = UTType(filenameExtension: "xlsx"), !types.contains(xlsx) {
            types.append(xlsx)
        }
        return types
    }

    private func handleSelectedFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure = result {
                errorMessage = "所选文件无法读取。"
            }
            return
        }

        do {
            importPreview = try viewModel.previewImport(url: url, strictMatching: false)
            isShowingImportPreview = true
        } catch {
            errorMessage = "文件预览失败。\n\(error.localizedDescription)"
        }
    }

    private func importSummary(_ result: ImportResult) -> String {
        var summary = "新增 \(result.insertedCount) 人，更新 \(result.updatedCount) 人，拒绝 \(result.rejectedCount) 行。"
        if !result.reviewedRowNumbers.isEmpty {
            summary += "需要复核的行：\(result.reviewedRowNumbers.map(String.init).joined(separator: "、"))。"
        }
        return summary
    }
}

private struct StudentCardView: View {
    let student: StudentSummary

    var body: some View {
        let appearance = StudentGenderAppearance(gender: student.gender)

        HStack(spacing: 14) {
            InitialBadge(text: student.name, size: 52, color: appearance.accent)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(student.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    if let gender = ValueNormalizer.optionalText(student.gender) {
                        Text(gender)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(appearance.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(appearance.accent.opacity(0.12), in: Capsule())
                    }
                }

                Label(student.className ?? "当前班级未录入", systemImage: "person.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let studentNumber = student.studentNumber {
                    Text("学号：\(studentNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(appearance.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(appearance.accent)
                .frame(width: 5)
                .padding(.vertical, 14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                .stroke(appearance.accent.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: appearance.accent.opacity(0.08), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }
}

private struct StudentEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let repository: StudentRepository
    let onSaved: () -> Void

    @State private var name = ""
    @State private var className = ""
    @State private var studentNumber = ""
    @State private var gender = ""
    @State private var idNumber = ""
    @State private var primarySchoolName = ""
    @State private var primarySchoolClass = ""
    @State private var familyAddress = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("姓名（必填）", text: $name)
                        .textContentType(.name)

                    TextField("当前班级（建议填写）", text: $className)

                    TextField("学号（可选）", text: $studentNumber)
                        .textContentType(.username)

                    Picker("性别", selection: $gender) {
                        Text("未录入").tag("")
                        Text("男").tag("男")
                        Text("女").tag("女")
                        Text("其他").tag("其他")
                    }
                } header: {
                    Text("基本信息")
                } footer: {
                    Text("当前班级用于列表筛选；小学班级只作为辅助历史信息保存。")
                }

                Section("其他信息（可选）") {
                    TextField("身份证号", text: $idNumber)
                        .textContentType(.username)

                    TextField("毕业学校名称", text: $primarySchoolName)

                    TextField("小学班级", text: $primarySchoolClass)

                    TextField("家庭地址", text: $familyAddress, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("新增学生")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .bold()
                        .accessibilityIdentifier("save-student-button")
                }
            }
            .alert("学生未保存", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "学生信息无法保存。")
            }
        }
        .accessibilityIdentifier("student-editor")
    }

    private func save() {
        let draft = StudentDraft(
            name: name,
            className: className,
            studentNumber: studentNumber,
            gender: gender,
            idNumber: idNumber,
            primarySchoolName: primarySchoolName,
            primarySchoolClass: primarySchoolClass,
            familyAddress: familyAddress
        )

        do {
            _ = try repository.addStudent(draft: draft)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
