import SwiftUI

/// Shows exactly which fields a merge would retain, before anything is approved.
///
/// Required by §16: the user sees the resulting record field by field, and the
/// confirm button only records the *intent*. The merge itself happens later,
/// after the Review screen's final confirmation.
struct ContactMergePreview: View {

    let group: ContactDuplicateGroup
    let onConfirm: (ContactMergeInstruction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keepID: String

    init(group: ContactDuplicateGroup,
         onConfirm: @escaping (ContactMergeInstruction) -> Void) {
        self.group = group
        self.onConfirm = onConfirm
        _keepID = State(initialValue: group.suggestedKeepID)
    }

    private var merged: ContactRecord { group.mergedPreview }

    private var absorbed: [ContactRecord] {
        group.members.filter { $0.id != keepID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    intro
                    baseRecordPicker
                    resultingFields
                    warningIfNeeded
                }
                .padding(Theme.Space.md)
            }
            .screenBackground()
            .navigationTitle("Review merge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(
                    title: "Merge \(group.members.count) contacts",
                    subtitle: "Confirmed at the final review step",
                    systemImage: "arrow.triangle.merge"
                ) {
                    onConfirm(instruction)
                }
                .padding(Theme.Space.md)
                .background(.bar)
            }
        }
    }

    private var intro: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("This merge keeps every piece of information")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.ink)
                Text("Phone numbers and email addresses from all \(group.members.count) records are combined. Nothing is discarded, and nothing happens until you confirm on the review screen.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var baseRecordPicker: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Overline(text: "Record to keep")
                Text("The other records are deleted once their details are copied across.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.inkSecondary)
                ForEach(group.members) { member in
                    Button {
                        keepID = member.id
                    } label: {
                        HStack(spacing: Theme.Space.xs) {
                            Image(systemName: member.id == keepID
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(member.id == keepID
                                                 ? Theme.Palette.accent
                                                 : Theme.Palette.inkTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.displayName)
                                    .font(Theme.Typography.callout)
                                    .foregroundStyle(Theme.Palette.ink)
                                Text(Format.count(member.fieldCount, singular: "field"))
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.inkTertiary)
                            }
                            Spacer()
                        }
                        .frame(minHeight: Theme.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(member.id == keepID ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private var resultingFields: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Overline(text: "Resulting contact")
                field("Name", values: [displayName].filter { !$0.isEmpty })
                if !merged.organizationName.isEmpty {
                    field("Company", values: [merged.organizationName])
                }
                if !merged.phoneNumbers.isEmpty {
                    field("Phone", values: merged.phoneNumbers)
                }
                if !merged.emailAddresses.isEmpty {
                    field("Email", values: merged.emailAddresses)
                }
            }
        }
    }

    private var displayName: String {
        [merged.givenName, merged.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func field(_ label: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Overline(text: label)
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(values.joined(separator: ", "))")
    }

    /// §16: where a merge cannot be done safely, say so and steer to the safer
    /// Delete/Ignore path rather than risking data loss.
    @ViewBuilder
    private var warningIfNeeded: some View {
        if merged.phoneNumbers.isEmpty && merged.emailAddresses.isEmpty {
            Card {
                HStack(alignment: .top, spacing: Theme.Space.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Palette.destructive)
                    Text("These records have no phone number or email between them. Merging is still safe, but deleting the extra copies may be simpler — you can close this and use Delete extras instead.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var instruction: ContactMergeInstruction {
        ContactMergeInstruction(
            id: group.id,
            keepID: keepID,
            absorbedIDs: absorbed.map(\.id),
            resultingPhoneNumbers: merged.phoneNumbers,
            resultingEmailAddresses: merged.emailAddresses,
            resultingGivenName: merged.givenName,
            resultingFamilyName: merged.familyName,
            resultingOrganization: merged.organizationName
        )
    }
}
