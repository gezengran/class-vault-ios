import SwiftUI

struct ContactEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let repository: StudentRepository
    let studentID: String
    let existingContact: ParentContact?
    let onSaved: () -> Void

    @State private var name: String
    @State private var relationChoice: RelationChoice
    @State private var customRelation: String
    @State private var phone: String
    @State private var contactRole: ContactRole
    @State private var isPrimary: Bool
    @State private var errorMessage: String?

    init(
        repository: StudentRepository,
        studentID: String,
        existingContact: ParentContact?,
        onSaved: @escaping () -> Void
    ) {
        self.repository = repository
        self.studentID = studentID
        self.existingContact = existingContact
        self.onSaved = onSaved

        let existingRelation = existingContact?.relation ?? ""
        let knownRelation = RelationChoice(rawValue: existingRelation)
        _name = State(initialValue: existingContact?.name ?? "")
        _relationChoice = State(initialValue: knownRelation ?? (existingRelation.isEmpty ? .notEntered : .custom))
        _customRelation = State(initialValue: knownRelation == nil ? existingRelation : "")
        _phone = State(initialValue: existingContact?.phone ?? "")
        _contactRole = State(initialValue: ContactRole(rawValue: existingContact?.contactRole ?? "") ?? .unknown)
        _isPrimary = State(initialValue: existingContact?.isPrimary ?? false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(existingContact == nil ? "新增联系人" : "编辑联系人")
                            .font(.title2.weight(.bold))
                        Text("可以先保存部分信息，之后再补充家长姓名、关系或电话号码。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    AppCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("基本信息")
                                .font(.headline.weight(.bold))

                            TextField("家长姓名（可选）", text: $name)
                                .textContentType(.name)
                                .textFieldStyle(.roundedBorder)

                            Picker("关系", selection: $relationChoice) {
                                ForEach(RelationChoice.allCases) { choice in
                                    Text(choice.displayName).tag(choice)
                                }
                            }
                            .pickerStyle(.menu)

                            if relationChoice == .custom {
                                TextField("自定义关系", text: $customRelation)
                                    .textFieldStyle(.roundedBorder)
                            }

                            TextField("电话号码（可选）", text: $phone)
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    AppCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("联系人分类")
                                .font(.headline.weight(.bold))

                            Picker("联系人类型", selection: $contactRole) {
                                ForEach(ContactRole.allCases, id: \.self) { role in
                                    Text(role.displayName).tag(role)
                                }
                            }
                            .pickerStyle(.menu)

                            Toggle("设为主要联系人", isOn: $isPrimary)
                        }
                    }

                    Label("电话号码有效后，学生详情页才会显示拨打按钮。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle(existingContact == nil ? "新增联系人" : "编辑联系人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .bold()
                        .accessibilityIdentifier("save-contact-button")
                }
            }
            .alert("联系人未保存", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "联系人无法保存。")
            }
        }
        .accessibilityIdentifier("contact-editor")
    }

    private func save() {
        let relation: String?
        switch relationChoice {
        case .notEntered:
            relation = nil
        case .father, .mother, .guardian, .other:
            relation = relationChoice.rawValue
        case .custom:
            relation = customRelation
        }

        let draft = ParentContactDraft(
            name: name,
            relation: relation,
            phone: phone,
            contactRole: contactRole.rawValue,
            isPrimary: isPrimary
        )
        do {
            if let existingContact {
                _ = try repository.updateParentContact(contactID: existingContact.id, draft: draft)
            } else {
                _ = try repository.addParentContact(studentID: studentID, draft: draft)
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = "请检查联系人信息和电话号码格式。"
        }
    }
}

private enum RelationChoice: String, CaseIterable, Hashable, Identifiable {
    case notEntered = ""
    case father = "父亲"
    case mother = "母亲"
    case guardian = "监护人"
    case other = "其他"
    case custom = "custom"

    var id: String { rawValue.isEmpty ? "not-entered" : rawValue }

    var displayName: String {
        switch self {
        case .notEntered: "未录入"
        case .father: "父亲"
        case .mother: "母亲"
        case .guardian: "监护人"
        case .other: "其他"
        case .custom: "自定义"
        }
    }
}
