import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum HubSection: String, CaseIterable, Identifiable {
    case home, history, dictionary, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "首頁"
        case .history: "歷史紀錄"
        case .dictionary: "字典"
        case .settings: "設定"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .dictionary: "character.book.closed"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class HubState: ObservableObject {
    @Published var section: HubSection = .home
    /// Pre-filled word when opened from "將單字加入字典".
    @Published var pendingWord: String?
    weak var controller: DictationController?
}

struct HubView: View {
    @ObservedObject var state: HubState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $state.section)
            Rectangle().fill(Theme.separator).frame(width: 1)
            Group {
                switch state.section {
                case .home: HomeView(onShowHistory: { state.section = .history })
                case .history: HistoryView(controller: state.controller)
                case .dictionary: DictionaryView(pendingWord: $state.pendingWord)
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        // The window's title bar is transparent; the sidebar and pages run up under it.
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 620)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var section: HubSection
    @ObservedObject private var stats = StatsStore.shared
    @AppStorage("pressMode") private var pressMode = PressMode.both.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LogoHeader()
                .padding(.top, 46) // below the window buttons
                .padding(.bottom, 20)
            VStack(spacing: 2) {
                ForEach(HubSection.allCases) { item in
                    SidebarItem(section: item, selected: section == item) { section = item }
                }
            }
            Spacer()
            triggerHint
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 216)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    /// How to start, always in view, with today's count.
    private var triggerHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                let hold = PressMode(rawValue: pressMode) == .hold
                Text(hold ? "按住" : "按一下").font(.system(size: 12)).foregroundStyle(Theme.secondaryInk)
                KeyCap(label: Prefs.triggerKey.shortLabel)
                Text(hold ? "說話" : "開始說話").font(.system(size: 12)).foregroundStyle(Theme.secondaryInk)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("今天").font(.system(size: 12)).foregroundStyle(Theme.tertiaryInk)
                Text((stats.days[StatsStore.key(Date())]?.words ?? 0).formatted())
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text("字").font(.system(size: 12)).foregroundStyle(Theme.tertiaryInk)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill))
    }
}

struct SidebarItem: View {
    var section: HubSection
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "\(section.symbol).fill" : section.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(section.title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? Theme.ink : Theme.secondaryInk)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.selection)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The app's logo and name above the sidebar; the logo switches with light and dark mode.
struct LogoHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("logoStyle") private var logoStyle = LogoStyle.handwritten.rawValue

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: LogoMark.icon(dark: colorScheme == .dark, style: LogoStyle(rawValue: logoStyle) ?? .handwritten))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("Articulate").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("用說的，就寫好了").font(.system(size: 12)).foregroundStyle(Theme.tertiaryInk)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Home

struct HomeView: View {
    var onShowHistory: () -> Void = {}
    @ObservedObject private var stats = StatsStore.shared
    @ObservedObject private var history = HistoryStore.shared
    @AppStorage("pressMode") private var pressModeSetting = PressMode.both.rawValue
    private var pressMode: PressMode { PressMode(rawValue: pressModeSetting) ?? .both }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: Self.greeting(), subtitle: pressMode.howTo(Prefs.triggerKey.shortLabel) + "文字會出現在游標的位置。")
                    .padding(.bottom, 6)
                hero
                HStack(spacing: 12) {
                    MetricCard(symbol: "waveform", title: "總口述時間", value: Self.duration(stats.totalSeconds).value, unit: Self.duration(stats.totalSeconds).unit)
                    MetricCard(symbol: "speedometer", title: "平均速度", value: "\(stats.averageWPM)", unit: "字／分")
                    MetricCard(symbol: "flame", title: "連續天數", value: "\(stats.currentStreak)", unit: "天")
                    MetricCard(symbol: "trophy", title: "最長連續", value: "\(stats.longestStreak)", unit: "天")
                }
                activity
                HStack(alignment: .top, spacing: 12) {
                    shortcuts
                    recent
                }
            }
            .page()
        }
        .scrollContentBackground(.hidden)
    }

    /// The headline: everything written by voice, and the time it saved.
    private var hero: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("你已經用說的寫了").font(.system(size: 14)).foregroundStyle(Theme.secondaryInk)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(stats.totalWords.formatted())
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                    Text("字").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.secondaryInk)
                }
                let saved = Self.duration(stats.timeSavedSeconds)
                HStack(spacing: 6) {
                    Image(systemName: "hourglass").font(.system(size: 12, weight: .semibold))
                    Text("比打字省下 \(saved.value) \(saved.unit)").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Theme.accentSoft))
            }
            Spacer(minLength: 0)
            HeroWave().frame(width: 240, height: 84)
        }
        .card(padding: 24)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("每日活躍").font(Theme.cardTitle()).foregroundStyle(Theme.ink)
                Spacer()
                Text("共 \(stats.activeDays.count) 天有口述").font(.system(size: 12)).foregroundStyle(Theme.secondaryInk)
            }
            ActivityHeatmap(days: stats.days)
        }
        .card()
    }

    private var shortcuts: some View {
        let key = Prefs.triggerKey.shortLabel
        return VStack(alignment: .leading, spacing: 12) {
            Text("快捷鍵").font(Theme.cardTitle()).foregroundStyle(Theme.ink)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 11) {
                if pressMode != .hold { shortcut([key], "口述：按一下開始，再按一下輸入") }
                if pressMode != .toggle { shortcut([key], "按住說話，放開輸入", prefix: "按住") }
                shortcut([key, "空白鍵"], "隨便問：改寫選取的文字、回答問題")
                shortcut([key, "右 Shift"], "翻譯；錄音中再按右 Shift 換語言")
                shortcut(["Esc"], "取消")
                shortcut(["⌃", "⌘", "V"], "貼上上一次的結果")
            }
        }
        .card()
    }

    private func shortcut(_ keys: [String], _ text: String, prefix: String? = nil) -> some View {
        GridRow {
            HStack(spacing: 4) {
                if let prefix { Text(prefix).font(.system(size: 12)).foregroundStyle(Theme.secondaryInk) }
                ForEach(keys.indices, id: \.self) { i in
                    if i > 0 { Text("+").font(.system(size: 12)).foregroundStyle(Theme.tertiaryInk) }
                    KeyCap(label: keys[i])
                }
            }
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The last few dictations, with a way into the full history.
    private var recent: some View {
        let entries = history.entries.filter { $0.effectiveStatus == .completed && !$0.finalText.isEmpty }.prefix(3)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近").font(Theme.cardTitle()).foregroundStyle(Theme.ink)
                Spacer()
                Button(action: onShowHistory) {
                    HStack(spacing: 3) {
                        Text("全部紀錄")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            if entries.isEmpty {
                Text("還沒有紀錄。按一下 \(Prefs.triggerKey.shortLabel) 說說看。")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondaryInk)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 10) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.finalText).font(.system(size: 14)).foregroundStyle(Theme.ink).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(entry.date, format: .relative(presentation: .named))
                                if let app = entry.appName { Text("·"); Text(app) }
                            }
                            .font(.system(size: 12)).foregroundStyle(Theme.tertiaryInk)
                        }
                    }
                }
            }
        }
        .card()
    }

    static func greeting(at date: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "早安"
        case 12..<18: "午安"
        case 18..<23: "晚安"
        default: "夜深了"
        }
    }

    static func duration(_ seconds: Double) -> (value: String, unit: String) {
        if seconds >= 3600 { return (String(format: "%.1f", seconds / 3600), "小時") }
        return ("\(Int(seconds / 60))", "分鐘")
    }
}

/// A metric with a tinted icon.
struct MetricCard: View {
    var symbol: String
    var title: String
    var value: String
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundStyle(Theme.secondaryInk)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(Theme.ink).monospacedDigit()
                    Text(unit).font(.system(size: 12)).foregroundStyle(Theme.secondaryInk)
                }
            }
        }
        .card(padding: 16)
    }
}

/// A still waveform in the accent color, echoing the recording bar.
struct HeroWave: View {
    var body: some View {
        Canvas { context, size in
            let count = 30
            let step = size.width / CGFloat(count)
            let barWidth = step * 0.5
            for i in 0..<count {
                let t = Double(i)
                let level = 0.18 + 0.82 * abs(sin(t * 0.42) * cos(t * 0.13 + 0.6))
                let height = max(barWidth, size.height * level)
                let rect = CGRect(x: CGFloat(i) * step + (step - barWidth) / 2, y: (size.height - height) / 2,
                                  width: barWidth, height: height)
                let opacity = 0.25 + 0.75 * (1 - abs(t - Double(count) / 2) / (Double(count) / 2))
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(Theme.accent.opacity(opacity)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Days as a grid of weeks (newest on the right), shaded by how much was dictated.
struct ActivityHeatmap: View {
    var days: [String: StatsStore.Day]
    @State private var hovered: String?
    private static let cell: CGFloat = 13
    private static let gap: CGFloat = 4
    private static let labelWidth: CGFloat = 22

    /// One day per cell, column by column (a week per column); nil for days still ahead.
    private static func dates(weeks: Int) -> [Date?] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) - 1
        let start = calendar.date(byAdding: .day, value: -((weeks - 1) * 7 + weekday), to: today)!
        return (0..<weeks * 7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            return date > today ? nil : date
        }
    }

    /// 0 for no dictation, else 1–4 relative to the busiest day.
    private func level(_ words: Int, busiest: Int) -> Int {
        guard words > 0, busiest > 0 else { return 0 }
        return min(4, max(1, Int(ceil(4 * Double(words) / Double(busiest)))))
    }

    private static let shades: [Double] = [0, 0.3, 0.5, 0.72, 1]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let step = Self.cell + Self.gap
                let weeks = min(53, max(12, Int((geometry.size.width - Self.labelWidth + Self.gap) / step)))
                let dates = Self.dates(weeks: weeks)
                let busiest = days.values.map(\.words).max() ?? 0
                Canvas { context, _ in
                    // Month names above the first column of each month.
                    var lastMonth = -1, lastLabel = -10
                    for column in 0..<weeks {
                        guard let date = dates[column * 7 + 6] ?? dates[column * 7] else { continue }
                        let month = Calendar.current.component(.month, from: date)
                        guard month != lastMonth else { continue }
                        lastMonth = month
                        guard column - lastLabel >= 3 else { continue }
                        lastLabel = column
                        context.draw(Text("\(month)月").font(.system(size: 10)).foregroundStyle(Theme.tertiaryInk),
                                     at: CGPoint(x: Self.labelWidth + CGFloat(column) * step, y: 6), anchor: .leading)
                    }
                    for (row, name) in [(1, "一"), (3, "三"), (5, "五")] {
                        context.draw(Text(name).font(.system(size: 10)).foregroundStyle(Theme.tertiaryInk),
                                     at: CGPoint(x: 0, y: 18 + CGFloat(row) * step + Self.cell / 2), anchor: .leading)
                    }
                    for (i, date) in dates.enumerated() {
                        guard let date else { continue }
                        let words = days[StatsStore.key(date)]?.words ?? 0
                        let shade = Self.shades[level(words, busiest: busiest)]
                        let rect = CGRect(x: Self.labelWidth + CGFloat(i / 7) * step, y: 18 + CGFloat(i % 7) * step,
                                          width: Self.cell, height: Self.cell)
                        context.fill(Path(roundedRect: rect, cornerRadius: 3.5),
                                     with: .color(shade == 0 ? Theme.fill : Theme.accent.opacity(shade)))
                    }
                }
                .onContinuousHover { phase in
                    guard case .active(let point) = phase, point.x >= Self.labelWidth, point.y >= 18 else { hovered = nil; return }
                    let index = Int((point.x - Self.labelWidth) / step) * 7 + Int((point.y - 18) / step)
                    hovered = dates.indices.contains(index) ? dates[index].map(StatsStore.key) : nil
                }
            }
            .frame(height: 18 + 7 * Self.cell + 6 * Self.gap)
            HStack {
                Text(hoverText).font(.system(size: 12)).foregroundStyle(Theme.secondaryInk)
                Spacer()
                HStack(spacing: 3) {
                    Text("少").font(.system(size: 10)).foregroundStyle(Theme.tertiaryInk).padding(.trailing, 2)
                    ForEach(Self.shades.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3).fill(i == 0 ? Theme.fill : Theme.accent.opacity(Self.shades[i]))
                            .frame(width: 10, height: 10)
                    }
                    Text("多").font(.system(size: 10)).foregroundStyle(Theme.tertiaryInk).padding(.leading, 2)
                }
            }
        }
    }

    private var hoverText: String {
        guard let hovered else { return " " }
        let words = days[hovered]?.words ?? 0
        return words > 0 ? "\(hovered)　\(words.formatted()) 字" : "\(hovered)　沒有口述"
    }
}

// MARK: - History

struct HistoryView: View {
    weak var controller: DictationController?
    @ObservedObject private var history = HistoryStore.shared
    @AppStorage("historyRetention") private var retention = HistoryRetention.forever.rawValue
    @State private var tab = "all"
    @State private var search = ""
    @State private var confirmDeleteAll = false
    @State private var working: UUID?
    /// Entries whose recording is still on disk; checked once per change, not while rows render.
    @State private var withAudio: Set<UUID> = []
    @State private var pendingDelete: HistoryEntry?

    private var filtered: [HistoryEntry] {
        history.entries.filter {
            (tab == "all" || $0.effectiveMode.rawValue == tab)
                && (search.isEmpty || $0.finalText.localizedCaseInsensitiveContains(search) || $0.raw.localizedCaseInsensitiveContains(search))
        }
    }

    /// Entries by day, newest first.
    private var groups: [(title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var result: [(title: String, entries: [HistoryEntry])] = []
        var currentDay: Date?
        for entry in filtered {
            let day = calendar.startOfDay(for: entry.date)
            if day != currentDay {
                currentDay = day
                let title = calendar.isDateInToday(day) ? "今天"
                    : calendar.isDateInYesterday(day) ? "昨天"
                    : day.formatted(.dateTime.month().day().weekday(.wide))
                result.append((title, []))
            }
            result[result.count - 1].entries.append(entry)
        }
        return result
    }

    private var retentionLabel: String { HistoryRetention(rawValue: retention)?.label ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "歷史紀錄", subtitle: "\(history.entries.count.formatted()) 筆紀錄・保留\(retentionLabel)") {
                Menu {
                    Picker("保留紀錄", selection: $retention) {
                        ForEach(HistoryRetention.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("全部刪除…", role: .destructive) { confirmDeleteAll = true }
                        .disabled(history.entries.isEmpty)
                } label: {
                    Label("管理", systemImage: "slider.horizontal.3")
                }
                .menuStyle(.button)
                .buttonStyle(SecondaryButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .onChange(of: retention) { _, _ in history.applyRetention() }
            }
            HStack(spacing: 12) {
                PillPicker(selection: $tab, options: [
                    ("all", "全部"), (DictationMode.dictation.rawValue, "口述"),
                    (DictationMode.ask.rawValue, "隨便問"), (DictationMode.translation.rawValue, "翻譯"),
                ])
                Spacer()
                SearchField(text: $search, prompt: "搜尋紀錄").frame(width: 220)
            }
            if filtered.isEmpty {
                Spacer()
                EmptyState(symbol: search.isEmpty ? "clock" : "magnifyingglass",
                           title: search.isEmpty ? "還沒有紀錄" : "找不到符合的紀錄",
                           hint: search.isEmpty ? "按一下 \(Prefs.triggerKey.shortLabel) 開始說話，紀錄就會出現在這裡。" : nil)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.secondaryInk)
                                    .padding(.leading, 4)
                                VStack(spacing: 0) {
                                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                        if index > 0 { Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 72) }
                                        HistoryRow(entry: entry, hasAudio: withAudio.contains(entry.id), working: working == entry.id,
                                                   canRetry: working == nil && controller != nil,
                                                   onRetry: { retry(entry) }, onDownload: { download(entry) }, onDelete: { pendingDelete = entry })
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                                .card(padding: 0)
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollContentBackground(.hidden)
                .scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .frame(maxWidth: Theme.pageWidth, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .task(id: history.entries.map(\.id)) {
            let recordings = history.entries.compactMap { entry in entry.audioURL.map { (entry.id, $0.path) } }
            withAudio = await Task.detached {
                Set(recordings.filter { FileManager.default.fileExists(atPath: $0.1) }.map(\.0))
            }.value
        }
        .confirmationDialog("刪除這筆紀錄？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { entry in
            Button("刪除", role: .destructive) { history.delete([entry.id]) }
        } message: { _ in
            Text("這筆紀錄和它的錄音會永久刪除，無法恢復。")
        }
        .confirmationDialog("刪除所有紀錄？", isPresented: $confirmDeleteAll) {
            Button("全部刪除", role: .destructive) { history.clear() }
        } message: {
            Text("所有紀錄和錄音都會永久刪除，無法恢復。")
        }
    }

    /// Saves the recording somewhere the user picks.
    private func download(_ entry: HistoryEntry) {
        guard let source = entry.audioURL else { return }
        let panel = NSSavePanel()
        let stamp = entry.date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
        panel.nameFieldStringValue = "Articulate 錄音 \(stamp.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")).\(source.pathExtension)"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: source, to: target)
    }

    private func retry(_ entry: HistoryEntry) {
        guard let controller else { return }
        working = entry.id
        Task {
            _ = await controller.retry(entry.id)
            working = nil
        }
    }
}

/// One history entry. Like Typeless, its buttons appear only while the pointer is over the row; they are created
/// only then too, which keeps rows cheap to build while scrolling. The raw recognition is one click away.
struct HistoryRow: View {
    let entry: HistoryEntry
    let hasAudio: Bool
    let working: Bool
    let canRetry: Bool
    let onRetry: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var copied = false
    @State private var showRaw = false

    init(entry: HistoryEntry, hasAudio: Bool, working: Bool, canRetry: Bool, onRetry: @escaping () -> Void,
         onDownload: @escaping () -> Void, onDelete: @escaping () -> Void, hovering: Bool = false) {
        self.entry = entry
        self.hasAudio = hasAudio
        self.working = working
        self.canRetry = canRetry
        self.onRetry = onRetry
        self.onDownload = onDownload
        self.onDelete = onDelete
        _hovering = State(initialValue: hovering)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var hasRaw: Bool { entry.engine != nil && !entry.raw.isEmpty && entry.raw != entry.finalText }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(Self.time.string(from: entry.date))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.tertiaryInk)
                .frame(width: 40, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                if !entry.finalText.isEmpty {
                    Text(entry.finalText)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(Theme.bodyLineSpacing)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    if let app = entry.appName { Text(app).font(.system(size: 12)).foregroundStyle(Theme.secondaryInk) }
                    switch entry.effectiveMode {
                    case .translation: Tag(text: "翻譯→\(TranslationLanguages.label(entry.targetLanguage ?? ""))", color: Theme.accent)
                    case .ask: Tag(text: "隨便問", color: Theme.accent)
                    case .dictation: EmptyView()
                    }
                    switch entry.effectiveStatus {
                    case .cancelled: Tag(text: "已取消", color: .orange)
                    case .error: Tag(text: "失敗", color: .red)
                    case .empty: Tag(text: "沒有內容", color: Theme.secondaryInk)
                    case .completed: EmptyView()
                    }
                    if entry.revertedAI == true { Tag(text: "已撤銷 AI", color: Theme.secondaryInk) }
                    if entry.editedText != nil { Tag(text: "你有修改", color: .green) }
                    Spacer(minLength: 0)
                    if working { ProgressView().controlSize(.small) }
                    if hovering || copied { actions.transition(.opacity) }
                }
                .frame(minHeight: 24)
                if showRaw, hasRaw {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("原始辨識").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tertiaryInk)
                        Text(entry.raw).font(.system(size: 12)).foregroundStyle(Theme.secondaryInk).textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill))
                }
                if let error = entry.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(hovering ? Theme.cardHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeInOut(duration: 0.15)) { hovering = inside } }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if hasRaw {
                iconButton(showRaw ? "text.badge.minus" : "text.magnifyingglass", help: showRaw ? "隱藏原始辨識" : "顯示原始辨識") {
                    withAnimation(.easeInOut(duration: 0.15)) { showRaw.toggle() }
                }
            }
            if !entry.finalText.isEmpty {
                iconButton(copied ? "checkmark" : "doc.on.doc", tint: copied ? .green : Theme.secondaryInk, help: copied ? "已複製" : "複製") {
                    TextInserter.copyToPasteboard(entry.finalText)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.easeInOut(duration: 0.2)) { copied = false }
                    }
                }
            }
            Menu {
                if hasAudio {
                    Button(entry.effectiveStatus == .completed ? "重新轉錄" : "恢復", action: onRetry).disabled(!canRetry)
                    Button("下載錄音", action: onDownload)
                    Divider()
                }
                Button("刪除轉錄", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryInk)
                    .frame(width: 26, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
        }
    }

    private func iconButton(_ symbol: String, tint: Color = Theme.secondaryInk, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @Binding var pendingWord: String?
    @ObservedObject private var store = DictionaryStore.shared
    @State private var tab = "all"
    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var editing: DictionaryWord?
    @State private var adding = false
    @State private var draft = ""
    @State private var notice: String?

    private var filtered: [DictionaryWord] {
        store.words.filter { word in
            (tab == "all" || word.source.rawValue == tab)
                && (search.isEmpty || word.term.localizedCaseInsensitiveContains(search))
        }
    }

    private func count(_ source: DictionaryWord.Source) -> Int { store.words.filter { $0.source == source }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "字典", subtitle: "Articulate 會照這裡的寫法辨識和整理。你插入文字後手動改過的名稱，也會自動加進來。") {
                    HStack(spacing: 8) {
                        Button("匯入 CSV") { importCSV() }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("使用一欄的 CSV 檔案，每行一個單字。")
                        Button { draft = ""; adding = true } label: { Label("新增單字", systemImage: "plus") }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut("n")
                    }
                }
                HStack(spacing: 12) {
                    PillPicker(selection: $tab, options: [
                        ("all", "全部 \(store.words.count)"),
                        (DictionaryWord.Source.auto.rawValue, "自動新增 \(count(.auto))"),
                        (DictionaryWord.Source.manual.rawValue, "手動新增 \(count(.manual))"),
                    ])
                    Spacer()
                    SearchField(text: $search, prompt: "搜尋單字").frame(width: 220)
                }
                if !selection.isEmpty {
                    HStack(spacing: 10) {
                        Text("已選擇 \(selection.count) 個單字").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                        Spacer()
                        Button("取消選擇") { selection.removeAll() }.buttonStyle(SecondaryButtonStyle())
                        Button("刪除") {
                            store.delete(selection)
                            selection.removeAll()
                        }
                        .buttonStyle(SecondaryButtonStyle(tint: .red))
                    }
                    .card(padding: 12)
                }
                if let notice {
                    Label(notice, systemImage: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(.green)
                }
                if filtered.isEmpty {
                    EmptyState(symbol: search.isEmpty ? "character.book.closed" : "magnifyingglass",
                               title: search.isEmpty ? "字典還是空的" : "找不到符合的單字",
                               hint: search.isEmpty ? "加入人名、產品名、專有名詞，Articulate 就會照你的寫法輸出。" : nil)
                        .card()
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        FlowLayout(spacing: 8) {
                            ForEach(filtered) { word in
                                TermChip(word: word, selected: selection.contains(word.id),
                                         onToggle: { toggle(word.id) },
                                         onEdit: { draft = word.term; editing = word },
                                         onDelete: { store.delete([word.id]); selection.remove(word.id) })
                            }
                        }
                        HStack(spacing: 12) {
                            Label("自動學到的", systemImage: "sparkles").foregroundStyle(Theme.accent)
                            Text("點一下選取，雙擊編輯，右鍵有更多動作").foregroundStyle(Theme.tertiaryInk)
                        }
                        .font(.system(size: 12))
                    }
                    .card()
                }
            }
            .page()
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $adding) { wordSheet(title: "新增到字典", button: "新增單字") { store.add(draft, source: .manual) } }
        .sheet(item: $editing) { word in wordSheet(title: "編輯單字", button: "儲存") { store.update(word.id, term: draft) } }
        .onAppear(perform: consumePending)
        .onChange(of: pendingWord) { _, _ in consumePending() }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func consumePending() {
        guard let word = pendingWord else { return }
        pendingWord = nil
        draft = word
        adding = true
    }

    private func wordSheet(title: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 16, weight: .semibold))
            TextField("單字或名稱", text: $draft).textFieldStyle(.roundedBorder).frame(width: 320)
            if draft.count > DictionaryStore.maxTermLength { Text("名稱超過長度限制。").foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { adding = false; editing = nil }
                    .buttonStyle(SecondaryButtonStyle())
                Button(button) {
                    action()
                    adding = false
                    editing = nil
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || draft.count > DictionaryStore.maxTermLength)
            }
        }
        .padding(22)
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), data.count <= 5_000_000 else {
            notice = "檔案無法匯入（最大 5 MB）。"
            return
        }
        let terms = DictionaryStore.parseCSV(data)
        let added = store.importTerms(terms)
        notice = "\(url.lastPathComponent)：找到 \(terms.count) 個單字，新增了 \(added) 個。"
    }
}

/// A dictionary word as a chip. The delete button floats over the corner on hover, so the chip never changes size.
struct TermChip: View {
    let word: DictionaryWord
    let selected: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if word.source == .auto {
                Image(systemName: "sparkles").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            Text(word.term).font(.system(size: 14)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(selected ? Theme.accentSoft : (hovering ? Theme.cardHover : Theme.fill)))
        .overlay(Capsule().strokeBorder(selected ? Theme.accent : (hovering ? Theme.border : Color.clear), lineWidth: selected ? 1.5 : 1))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.canvas)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Theme.secondaryInk))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .help("刪除")
                .transition(.opacity)
            }
        }
        .contentShape(Capsule())
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(perform: onToggle)
        .onHover { inside in withAnimation(.easeInOut(duration: 0.12)) { hovering = inside } }
        .contextMenu {
            Button("編輯…", action: onEdit)
            Button(selected ? "取消選取" : "選取", action: onToggle)
            Divider()
            Button("刪除", role: .destructive, action: onDelete)
        }
        .help(word.source == .auto ? "由 Articulate 從你的修改自動學到" : "手動新增")
    }
}
