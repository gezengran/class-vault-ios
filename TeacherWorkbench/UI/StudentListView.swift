import SwiftUI
import UniformTypeIdentifiers

struct StudentListView: View {
    @EnvironmentObject private var container: AppContainer
    @StateObject private var viewModel: StudentListViewModel

    @State private var isShowingFileImporter = false
    @State private var isShowingImportPreview = false
    @State private var importPreview: ImportPreview?
    @State private var importResult: ImportResult?
    @State private var errorMessage: String?

    init(repository: StudentRepository) {
        _viewModel = StateObject(wrappedValue: StudentListViewModel(repository: repository))
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
                Text("只显示保存在本机加密数据库中的信息")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                NavigationLink {
                    StudentDetailView(repository: viewModel.repository, studentID: student.id)
                } label: {
                    StudentCardView(student: student)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("student-card-\(student.id)")
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
                Label("全部班级", systemImage: viewModel.selectedClass.isEmpty ? "checkmark" : "")
            }
            ForEach(viewModel.classNames, id: \.self) { className in
                Button {
                    viewModel.selectedClass = className
                } label: {
                    Label(className, systemImage: viewModel.selectedClass == className ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(viewModel.selectedClass.isEmpty ? "班级筛选" : "当前班级：\(viewModel.selectedClass)")
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
        AppCard {
            HStack(spacing: 14) {
                InitialBadge(text: student.name)

                VStack(alignment: .leading, spacing: 7) {
                    Text(student.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    if let className = student.className {
                        Label(className, systemImage: "person.2.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("班级未录入", systemImage: "person.2.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let studentNumber = student.studentNumber {
                        Text("学号：\(studentNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }
}
