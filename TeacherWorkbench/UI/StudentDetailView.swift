import SwiftUI

struct StudentDetailView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel: StudentDetailViewModel

    @State private var isShowingEditor = false
    @State private var editingContact: ParentContact?
    @State private var pendingArchiveID: String?
    @State private var pendingCall: ParentContact?
    @State private var errorMessage: String?

    init(repository: StudentRepository, studentID: String) {
        _viewModel = StateObject(wrappedValue: StudentDetailViewModel(repository: repository, studentID: studentID))
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if let details = viewModel.details {
                detailContent(details)
            } else if viewModel.errorMessage == nil {
                ProgressView("正在加载学生信息…")
            } else {
                ContentUnavailableView("学生信息不可用", systemImage: "person.crop.circle.badge.exclamationmark")
            }
        }
        .navigationTitle("学生详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { viewModel.load() }
        .sheet(isPresented: $isShowingEditor, onDismiss: {
            editingContact = nil
        }) {
            ContactEditorView(
                repository: viewModel.repository,
                studentID: viewModel.studentID,
                existingContact: editingContact,
                onSaved: { viewModel.load() }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "确认归档此联系人？",
            isPresented: Binding(
                get: { pendingArchiveID != nil },
                set: { if !$0 { pendingArchiveID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("归档", role: .destructive) {
                if let contactID = pendingArchiveID {
                    do {
                        try viewModel.archiveContact(contactID)
                    } catch {
                        errorMessage = "联系人归档失败。"
                    }
                }
                pendingArchiveID = nil
            }
            Button("取消", role: .cancel) { pendingArchiveID = nil }
        } message: {
            Text("归档后联系人不会出现在当前列表中，但历史记录仍会保留。")
        }
        .alert("确认拨打电话？", isPresented: Binding(
            get: { pendingCall != nil },
            set: { if !$0 { pendingCall = nil } }
        )) {
            Button("拨打") {
                if let phone = pendingCall?.phone, let url = PhoneCallService.url(for: phone) {
                    openURL(url)
                } else {
                    errorMessage = "该联系人没有有效的电话号码。"
                }
                pendingCall = nil
            }
            Button("取消", role: .cancel) { pendingCall = nil }
        } message: {
            Text(callMessage)
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

    @ViewBuilder
    private func detailContent(_ details: StudentDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                studentHero(details)
                studentInformation(details)
                contactsSection(details)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func studentHero(_ details: StudentDetails) -> some View {
        let appearance = StudentGenderAppearance(gender: details.gender)

        return HStack(spacing: 16) {
            InitialBadge(text: details.name, size: 68, color: .white.opacity(0.20))

            VStack(alignment: .leading, spacing: 6) {
                Text(details.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                if let className = details.bestAvailableClassName {
                    Text(className)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                } else {
                    Text("班级未录入")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                }

                if let gender = ValueNormalizer.optionalText(details.gender) {
                    Text(gender)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.16), in: Capsule())
                }
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(appearance.heroGradient, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }

    private func studentInformation(_ details: StudentDetails) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading("学生信息")

                VStack(spacing: 0) {
                    DetailValueRow(title: "学号", value: details.studentNumber ?? "未录入")
                    if let gender = details.gender {
                        DetailValueRow(title: "性别", value: gender)
                    }
                    if let currentClass = details.className {
                        DetailValueRow(title: "当前班级", value: currentClass)
                    }
                    if let primaryClass = details.primarySchoolClass {
                        DetailValueRow(title: "小学班级（辅助）", value: primaryClass)
                    }
                    if let school = details.primarySchoolName {
                        DetailValueRow(title: "毕业学校", value: school)
                    }
                    if let idNumber = details.idNumber {
                        DetailValueRow(title: "身份证号", value: idNumber)
                    }
                    if let address = details.familyAddress {
                        DetailValueRow(title: "家庭地址", value: address)
                    }
                }
            }
        }
    }

    private func contactsSection(_ details: StudentDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                SectionHeading(
                    "联系人",
                    subtitle: details.contacts.isEmpty ? "还没有联系人信息" : "共 \(details.contacts.count) 位联系人"
                )
                Spacer(minLength: 12)
                Button {
                    beginAddingContact()
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(AppTheme.accent, in: Circle())
                }
                .accessibilityLabel("新增联系人")
            }

            if details.contacts.isEmpty {
                AppCard {
                    VStack(spacing: 14) {
                        EmptyStateIllustration(systemImage: "person.crop.circle.badge.questionmark")
                        Text("暂未录入联系人")
                            .font(.headline.weight(.bold))
                        Text("可以先导入电话号码，之后再补充家长姓名和关系。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("新增联系人") { beginAddingContact() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(details.contacts) { contact in
                        ContactCard(
                            contact: contact,
                            onCall: { pendingCall = contact },
                            onEdit: { beginEditing(contact) },
                            onArchive: { pendingArchiveID = contact.id }
                        )
                    }
                }
            }
        }
    }

    private var callMessage: String {
        guard let contact = pendingCall, let phone = contact.phone else {
            return "没有可用的电话号码。"
        }
        let target = contact.name ?? contact.sourceColumn ?? "未命名联系人"
        return "\(target)\n\(phone)"
    }

    private func beginAddingContact() {
        editingContact = nil
        isShowingEditor = true
    }

    private func beginEditing(_ contact: ParentContact) {
        editingContact = contact
        isShowingEditor = true
    }
}

private struct DetailValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 9)
    }
}

private struct ContactCard: View {
    let contact: ParentContact
    let onCall: () -> Void
    let onEdit: () -> Void
    let onArchive: () -> Void

    private var displayName: String {
        contact.name ?? "未命名联系人"
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    InitialBadge(text: displayName, size: 44, color: AppTheme.accent.opacity(0.86))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.headline.weight(.bold))
                        Text(contact.relation ?? contact.sourceColumn ?? "关系未录入")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if contact.isPrimary {
                        Text("主要")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.success)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(AppTheme.success.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(AppTheme.accent)
                    Text(contact.phone ?? "电话号码未录入")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(contact.phone == nil ? .secondary : .primary)
                }

                if contact.name == nil || contact.relation == nil {
                    Label("信息尚未完整，可编辑补充", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                }

                HStack(spacing: 10) {
                    if contact.phone != nil, PhoneNumberNormalizer.validNormalized(contact.phone) != nil {
                        Button(action: onCall) {
                            Label("拨打", systemImage: "phone.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("call-contact-\(contact.id)")
                    } else {
                        Label("补充有效电话号码后才能拨打", systemImage: "phone.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .frame(width: 38, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("编辑联系人")

                    Menu {
                        Button("归档联系人", role: .destructive, action: onArchive)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 38, height: 34)
                    }
                    .accessibilityLabel("联系人操作")
                }
            }
        }
    }
}
