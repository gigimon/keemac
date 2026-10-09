import Domain
import SwiftUI

enum BreachCheckState: Equatable {
    case idle
    case running(done: Int, total: Int)
    case finished(BreachChecker.Result)
    case failed(String)
}

enum ReportTab: String, CaseIterable {
    case summary
    case health
    case breaches

    var title: String {
        switch self {
        case .summary:
            return L("Summary")
        case .health:
            return L("Password Health")
        case .breaches:
            return L("Breach Check")
        }
    }
}

struct DatabaseReportView: View {
    let report: DatabaseReport
    let fileName: String
    let rootPath: String
    let entriesByID: [UUID: VaultEntry]
    @Binding var tab: ReportTab
    @Binding var expiringWithinDays: Int
    @Binding var oldAfterDays: Int
    let breachState: BreachCheckState
    let onOpenEntry: (VaultEntry) -> Void
    let onChangeMasterKey: () -> Void
    let onRunBreachCheck: () -> Void

    private static let red = Color(lightHex: 0xE0281E, darkHex: 0xFF453A)
    private static let orange = Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A)
    private static let green = Color(lightHex: 0x1F9D45, darkHex: 0x30D158)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Database Report"))
                            .font(.system(size: 22, weight: .bold))
                            .kerning(-0.3)
                        Text(fileName + " · " + issueLine)
                            .font(.system(size: 12))
                            .foregroundStyle(KM.textSecondary)
                    }
                    Spacer(minLength: 0)
                    KMSegmentedControl(
                        options: ReportTab.allCases.map { ($0, $0.title) },
                        selection: $tab,
                        fontSize: 12,
                        horizontalPadding: 14
                    )
                }

                Group {
                    switch tab {
                    case .summary:
                        summary
                    case .health:
                        health
                    case .breaches:
                        breaches
                    }
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 44)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
    }

    private var issueLine: String {
        report.issueCount == 0 ? L("No issues found") : L("\(report.issueCount) issues need attention")
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(report.stats) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.label)
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                        Text(stat.value)
                            .font(.system(size: 28, weight: .bold))
                            .kerning(-0.5)
                            .monospacedDigit()
                        Text(stat.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 13)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .kmCard()
                }
            }

            masterKeyCard

            VStack(alignment: .leading, spacing: 6) {
                sectionTitle(L("Data completeness"))
                VStack(spacing: 0) {
                    ForEach(Array(report.coverage.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15))
                                .foregroundStyle(KM.accent)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label)
                                    .font(.system(size: 13))
                                Text(item.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(KM.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(item.count))
                                .font(.system(size: 17, weight: .semibold))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Rectangle().fill(KM.hairline).frame(height: 0.5)
                            }
                        }
                    }
                }
                .kmCard(cornerRadius: 14)
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle(L("Most used"))
                    entryList(report.mostUsed, emptyText: L("No usage recorded yet."))
                }
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle(L("Not opened in 6 months"))
                    entryList(report.stale, emptyText: L("Every entry was opened recently."))
                }
            }

            Text(L("Usage count and last-access date update when you copy a field or open a website. They are written to the database when it locks or on the next change."))
                .font(.system(size: 11))
                .foregroundStyle(KM.textTertiary)
                .padding(.horizontal, 4)
        }
    }

    private var masterKeyCard: some View {
        let status = report.masterKey
        let tint = status.isOverdue ? Self.orange : Self.green
        return HStack(spacing: 14) {
            Image(systemName: "key.fill")
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(Circle().fill(tint.opacity(0.14)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(L("Master key"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(status.isOverdue ? L("Change recommended") : L("Up to date"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.14)))
                }
                Text(masterKeyChangedLine(status))
                    .font(.system(size: 12))
                Text(masterKeyNote(status))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(L("Change Master Key…"), action: onChangeMasterKey)
                .buttonStyle(KMButtonStyle(kind: .raised, height: 30, horizontalPadding: 14))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .kmCard(cornerRadius: 14)
    }

    private func masterKeyChangedLine(_ status: DatabaseReport.MasterKeyStatus) -> String {
        guard let changedAt = status.changedAt, let age = status.ageDays else {
            return L("Last change date is unknown")
        }
        let date = changedAt.formatted(date: .abbreviated, time: .omitted)
        let ago = L("\(age) days ago")
        return L("Last changed \(date) · \(ago)")
    }

    private func masterKeyNote(_ status: DatabaseReport.MasterKeyStatus) -> String {
        guard let limit = status.recommendedDays else {
            return L("No change interval is set in the database policy.")
        }
        let every = L("every \(limit) days")
        if status.isOverdue, let age = status.ageDays {
            return L("Your database policy recommends changing it \(every).") + " " + L("It is \(age - limit) days overdue.")
        }
        return L("Recommended \(every).")
    }

    // MARK: - Health

    private var health: some View {
        VStack(spacing: 14) {
            healthSection(
                symbol: "calendar.badge.exclamationmark",
                color: Self.red,
                title: L("Expired and expiring"),
                description: L("Entries past their expiry date, or expiring within the selected window."),
                issues: report.expiring
            ) {
                KMSegmentedControl(
                    options: [7, 14, 30, 90].map { ($0, L("\($0) days")) },
                    selection: $expiringWithinDays,
                    fontSize: 11,
                    horizontalPadding: 10
                )
            }

            healthSection(
                symbol: "doc.on.doc",
                color: Self.orange,
                title: L("Reused passwords"),
                description: L("The same password protects more than one entry. A breach of one site exposes the others."),
                issues: report.reused
            )

            healthSection(
                symbol: "exclamationmark.shield",
                color: Self.red,
                title: L("Weak passwords"),
                description: weakDescription,
                issues: report.weak
            )

            healthSection(
                symbol: "clock.arrow.circlepath",
                color: Self.orange,
                title: L("Old passwords"),
                description: L("Passwords that haven’t changed within the selected period."),
                issues: report.old
            ) {
                KMSegmentedControl(
                    options: [(180, L("\(6) months")), (365, L("\(1) years")), (730, L("\(2) years"))],
                    selection: $oldAfterDays,
                    fontSize: 11,
                    horizontalPadding: 10
                )
            }
        }
    }

    private var weakDescription: String {
        let skipped = report.qualityCheckSkipped
        guard !skipped.isEmpty else {
            return L("Short, predictable or low-entropy passwords.")
        }
        let excluded = L("\(skipped.count) entries have quality check turned off and are excluded")
        let names = DatabaseReport.names(skipped)
        return L("Short, predictable or low-entropy passwords. \(excluded): \(names).")
    }

    private func healthSection(
        symbol: String,
        color: Color,
        title: String,
        description: String,
        issues: [DatabaseReport.EntryIssue]
    ) -> some View {
        healthSection(symbol: symbol, color: color, title: title, description: description, issues: issues) {
            EmptyView()
        }
    }

    private func healthSection<Accessory: View>(
        symbol: String,
        color: Color,
        title: String,
        description: String,
        issues: [DatabaseReport.EntryIssue],
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        let tint = issues.isEmpty ? Self.green : color
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        Text(String(issues.count))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 18)
                            .background(Capsule().fill(issues.isEmpty ? Color(light: .black(0.12), dark: .white(0.16)) : color))
                    }
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            if issues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(L("No issues found"))
                }
                .font(.system(size: 12))
                .foregroundStyle(Self.green)
                .padding(.leading, 54)
                .padding(.top, 4)
                .padding(.bottom, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(issues) { issue in
                        issueRow(issue, showsChevron: true)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .kmCard(cornerRadius: 14)
    }

    // MARK: - Breaches

    @ViewBuilder
    private var breaches: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch breachState {
            case .idle, .failed:
                breachIntro
            case .running(let done, let total):
                VStack(spacing: 0) {
                    Text(L("Checking \(done) of \(total)…"))
                        .font(.system(size: 13, weight: .semibold))
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 360)
                        .padding(.top, 12)
                    Text(L("Sending hash prefixes only"))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                .kmCard(cornerRadius: 16)
            case .finished(let result):
                breachResult(result)
            }
        }
    }

    private var breachIntro: some View {
        VStack(spacing: 0) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 24))
                .foregroundStyle(KM.accent)
                .frame(width: 52, height: 52)
                .background(Circle().fill(KM.accent.opacity(0.14)))
            Text(L("Check passwords against known breaches"))
                .font(.system(size: 17, weight: .bold))
                .padding(.top, 14)
            Text(L("KeeMac looks up each password in the Have I Been Pwned database. Your passwords never leave this Mac."))
                .font(.system(size: 13))
                .foregroundStyle(KM.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 460)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 10) {
                breachFact("number", L("Only the first 5 characters of each password’s SHA-1 hash are sent (k-anonymity). Matching happens locally."))
                breachFact("wifi", L("Requires a connection to api.pwnedpasswords.com. Runs only when you start it."))
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.top, 18)

            if case .failed(let message) = breachState {
                Label(L("Couldn’t reach Have I Been Pwned (\(message)). Check your connection and try again."), systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(KM.danger)
                    .padding(.top, 16)
            }

            Button(L("Check \(report.uniquePasswordCount) Passwords"), action: onRunBreachCheck)
                .buttonStyle(KMButtonStyle(kind: .primary, height: 34, horizontalPadding: 20, fontWeight: .semibold))
                .disabled(report.uniquePasswordCount == 0)
                .padding(.top, 20)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .kmCard(cornerRadius: 16)
    }

    private func breachFact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(KM.accent)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func breachResult(_ result: BreachChecker.Result) -> some View {
        let issues = result.breachedEntries
            .compactMap { id, count -> DatabaseReport.EntryIssue? in
                guard let entry = entriesByID[id] else {
                    return nil
                }
                return DatabaseReport.EntryIssue(
                    entry: entry,
                    detail: "",
                    meta: L("Seen \(count) times"),
                    severity: .critical
                )
            }
            .sorted { $0.entry.title.localizedCaseInsensitiveCompare($1.entry.title) == .orderedAscending }
        let found = !issues.isEmpty

        HStack(spacing: 14) {
            Image(systemName: found ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(found ? Self.red : Self.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(found
                     ? L("\(issues.count) entries use passwords found in known data breaches")
                     : L("None of your passwords appear in known data breaches"))
                    .font(.system(size: 14, weight: .semibold))
                Text(L("Checked \(result.checkedPasswordCount) unique passwords · just now"))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Check Again"), action: onRunBreachCheck)
                .buttonStyle(KMButtonStyle(kind: .raised, height: 30, horizontalPadding: 14, fontWeight: .regular))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .kmCard(cornerRadius: 14)

        if found {
            VStack(spacing: 0) {
                ForEach(issues) { issue in
                    issueRow(issue, showsChevron: true)
                }
            }
            .padding(6)
            .kmCard(cornerRadius: 14)

            Text(L("Change these passwords on the affected sites first, then update the entries."))
                .font(.system(size: 11))
                .foregroundStyle(KM.textTertiary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Rows

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .padding(.leading, 4)
    }

    private func entryList(_ issues: [DatabaseReport.EntryIssue], emptyText: String) -> some View {
        VStack(spacing: 0) {
            if issues.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(KM.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 14)
            } else {
                ForEach(issues) { issue in
                    issueRow(issue, showsChevron: false)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .kmCard(cornerRadius: 14)
    }

    private func issueRow(_ issue: DatabaseReport.EntryIssue, showsChevron: Bool) -> some View {
        ReportEntryRow(
            entry: issue.entry,
            subtitle: issue.detail.isEmpty
                ? GroupPathFormatter.display(issue.entry.groupPath, rootPath: rootPath)
                : issue.detail,
            meta: issue.meta,
            metaColor: metaColor(issue.severity),
            showsChevron: showsChevron
        ) {
            onOpenEntry(issue.entry)
        }
    }

    private func metaColor(_ severity: DatabaseReport.EntryIssue.Severity) -> Color {
        switch severity {
        case .critical:
            return Self.red
        case .warning:
            return Self.orange
        case .neutral:
            return KM.textSecondary
        }
    }
}

private struct ReportEntryRow: View {
    let entry: VaultEntry
    let subtitle: String
    let meta: String
    let metaColor: Color
    let showsChevron: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LetterTile(
                    title: entry.title,
                    size: 26,
                    cornerRadius: 7,
                    fontSize: 12,
                    colorHex: entry.backgroundColorHex,
                    iconPNGData: entry.iconPNGData,
                    iconID: entry.iconID
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(meta)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(metaColor)
                    .lineLimit(1)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(KM.chevron)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? KM.rowHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct KMSegmentedControl<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var fontSize: CGFloat = 12
    var horizontalPadding: CGFloat = 12
    /// Segments shown dimmed that can't be picked.
    var disabled: Set<Value> = []
    /// Segments get "<prefix>.<value>" identifiers for UI tests.
    var identifierPrefix: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.0 == selection
                let isDisabled = disabled.contains(option.0)
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: fontSize, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? Color(lightHex: 0xFFFFFF, darkHex: 0x636366) : Color.clear)
                                .shadow(color: .black.opacity(isSelected ? 0.15 : 0), radius: 1, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.45 : 1)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier(identifierPrefix.map { "\($0).\(option.0)" } ?? option.1)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(light: .black(0.06), dark: .white(0.08)))
        )
        .fixedSize()
    }
}
