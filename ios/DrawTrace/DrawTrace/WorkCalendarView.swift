import SwiftUI
import TraceKit

struct WorkCalendarView: View {
    let work: WorkDetail
    let days: [WorkHistoryDay]
    let store: AppGroupStore?
    @State private var month = Date()
    @State private var selectedDate: Date?
    @State private var selectedDay: WorkHistoryDay?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var calendar: Calendar { TraceDate.calendar }
    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
    }
    private var monthDays: [WorkHistoryDay] {
        days.filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }
    }
    private var previewDay: WorkHistoryDay? {
        monthDays.first { $0.date == selectedDate } ?? monthDays.first
    }
    private var cells: [Date?] {
        let leading = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
        let dates = Array<Date?>(repeating: nil, count: leading)
            + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: monthStart) }
        return dates + Array(repeating: nil, count: (7 - dates.count % 7) % 7)
    }
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            TraceSectionTitle(title: "制作の記録", systemImage: "calendar")
            VStack(alignment: .leading, spacing: 20) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 28) { monthGrid; dayPreview }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 28) {
                            monthGrid.frame(width: 330)
                            dayPreview.frame(minWidth: 230, maxWidth: .infinity)
                        }
                        VStack(spacing: 28) { monthGrid; dayPreview }
                    }
                }
                HStack(spacing: 18) {
                    Label("全体画像あり", systemImage: "square.fill").foregroundStyle(TraceStyle.green)
                    Label("受信記録のみ", systemImage: "circle").foregroundStyle(TraceStyle.secondaryGreen)
                }.font(.caption)
            }
            .padding(20)
            .background(TraceStyle.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TraceStyle.line))
            if days.isEmpty {
                ContentUnavailableView {
                    Label("記録なし", systemImage: "calendar.badge.plus")
                }
            } else if monthDays.isEmpty {
                InlineNotice(text: "この月の記録なし")
            } else {
                TraceSectionTitle(title: "日ごとの記録", systemImage: "clock")
                VStack(spacing: 0) {
                    ForEach(monthDays) { day in
                        Button { selectedDay = day } label: { historyRow(day) }
                            .buttonStyle(TraceButtonStyle()).accessibilityIdentifier("history.day")
                    }
                }
            }
        }
        .onAppear { month = days.first?.date ?? Date(); selectedDate = days.first?.date }
        .sheet(item: $selectedDay) { day in
            NavigationStack { WorkDayDetailView(work: work, day: day, store: store) }
                .preferredColorScheme(.dark).tint(TraceStyle.green)
                .presentationBackground(TraceStyle.background)
        }
    }

    private var monthGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 2) {
                Text(month.formatted(.dateTime.year().month(.wide).locale(TraceDate.locale)))
                    .font(.headline).foregroundStyle(TraceStyle.text)
                Spacer(minLength: 4)
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("前の月")
                Button("今日") { month = Date(); selectedDate = nil }.font(.caption).frame(minWidth: 44, minHeight: 44)
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("次の月")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 5) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption).foregroundStyle(TraceStyle.muted).frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let date {
                        let day = monthDays.first { calendar.isDate($0.date, inSameDayAs: date) }
                        Button { selectedDate = date } label: { calendarCell(date, day: day) }
                            .buttonStyle(.plain).disabled(day == nil)
                            .accessibilityLabel("\(date.formatted(.dateTime.month().day().locale(TraceDate.locale)))、\(day == nil ? "記録なし" : "全体画像を表示")")
                            .accessibilityIdentifier("calendar.day.\(calendar.component(.day, from: date))")
                    } else { Color.clear.frame(height: 62) }
                }
            }
        }
    }

    private var dayPreview: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let day = previewDay {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(TraceDate.dayNumber(day.date))
                        .font(.system(size: 36, weight: .semibold).monospacedDigit())
                        .tracking(-1).foregroundStyle(TraceStyle.text)
                    Text(day.date.formatted(.dateTime.month().weekday(.wide).locale(TraceDate.locale)))
                        .font(.caption).foregroundStyle(TraceStyle.muted)
                }
                Button { selectedDay = day } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        WorkThumbnail(url: imageURL(day.lastSnapshot), emptyText: "全体画像なし", crop: day.lastSnapshot?.item.rect)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("記録 \(day.records.count)回 ・ 最後の全体画像").font(.caption).foregroundStyle(TraceStyle.muted)
                            if let snap = day.lastSnapshot {
                                Text(TraceDate.time(snap.item.frameTime)).font(.system(.headline).monospacedDigit())
                                    .foregroundStyle(TraceStyle.text)
                            }
                            Label("詳細", systemImage: "arrow.up.right")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(TraceStyle.green)
                        }
                    }
                }.buttonStyle(TraceButtonStyle()).accessibilityIdentifier("history.selection")
            } else {
                Image(systemName: "calendar").font(.largeTitle).foregroundStyle(TraceStyle.muted)
                Text("記録なし").font(.headline)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    private func calendarCell(_ date: Date, day: WorkHistoryDay?) -> some View {
        let selected = previewDay?.date == date
        return VStack(spacing: 4) {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(.caption).monospacedDigit().weight(selected ? .bold : .regular))
                .foregroundStyle(calendar.isDateInToday(date) ? TraceStyle.green : day == nil ? TraceStyle.muted : TraceStyle.text)
            if let day {
                SnapshotView(url: imageURL(day.lastSnapshot), compact: true, crop: day.lastSnapshot?.item.rect)
                    .frame(height: 27).padding(.horizontal, 3)
                    .overlay(alignment: .bottomTrailing) {
                        if day.lastSnapshot == nil {
                            Circle().strokeBorder(TraceStyle.secondaryGreen, lineWidth: 1).frame(width: 5, height: 5)
                        } else {
                            Rectangle().fill(TraceStyle.green).frame(width: 4, height: 4)
                        }
                    }
            } else { Color.clear.frame(height: 27) }
        }
        .frame(maxWidth: .infinity).frame(height: 62)
        .background(selected ? TraceStyle.mint : .clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? TraceStyle.green : .clear, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func historyRow(_ day: WorkHistoryDay) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(TraceDate.dayNumber(day.date))
                    .font(.system(.title2).monospacedDigit().weight(.semibold)).foregroundStyle(TraceStyle.text)
                Text(day.date.formatted(.dateTime.month().weekday(.abbreviated).locale(TraceDate.locale)))
                    .font(.caption).foregroundStyle(TraceStyle.muted)
            }.frame(width: 72, alignment: .leading)
            WorkThumbnail(url: imageURL(day.lastSnapshot), compact: true, crop: day.lastSnapshot?.item.rect)
                .frame(width: 88).padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 8) {
                Text(day.records.map { "\($0.index + 1)回目" }.joined(separator: "・"))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(TraceStyle.text)
                Text(day.lastSnapshot == nil ? "全体画像なし" : "最後の全体画像")
                    .font(.caption).foregroundStyle(TraceStyle.muted)
                if let snap = day.lastSnapshot {
                    Text(TraceDate.time(snap.item.frameTime)).font(.system(.subheadline).monospacedDigit())
                        .foregroundStyle(TraceStyle.text)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.subheadline).foregroundStyle(TraceStyle.green)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(TraceStyle.line).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func changeMonth(_ amount: Int) {
        month = calendar.date(byAdding: .month, value: amount, to: monthStart) ?? month
        selectedDate = nil
    }

    private func imageURL(_ snap: HistorySnapshot?) -> URL? {
        guard let snap, let store else { return nil }
        return store.directory(.images, sid: snap.sid).appendingPathComponent("\(snap.item.sha).jpg")
    }
}

private struct WorkDayDetailView: View {
    let work: WorkDetail
    let day: WorkHistoryDay
    let store: AppGroupStore?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(work.title).font(.subheadline).foregroundStyle(TraceStyle.muted)
                    Text(day.date.formatted(.dateTime.month().day().locale(TraceDate.locale)))
                        .font(.system(size: 32, weight: .semibold)).foregroundStyle(TraceStyle.text)
                    TraceBadge(text: day.date.formatted(.dateTime.weekday(.wide).locale(TraceDate.locale)))
                }
                VStack(alignment: .leading, spacing: 22) {
                    Text("最後の全体画像").font(.title3.weight(.semibold)).accessibilityIdentifier("history.lastSnapshot")
                    WorkThumbnail(url: imageURL(day.lastSnapshot), emptyText: "全体画像なし", crop: day.lastSnapshot?.item.rect)
                    if let snap = day.lastSnapshot {
                        Text(TraceDate.time(snap.item.frameTime))
                            .font(.system(.caption).monospacedDigit()).foregroundStyle(TraceStyle.green)
                    }
                }
                // 【T14】この日の記録ごとに、受信区間と全体画像
                ForEach(day.records) { record in
                    TracePanel(title: "\(record.index + 1)回目の記録", systemImage: "record.circle") {
                        HStack(spacing: 12) {
                            TraceBadge(text: record.final ? "正常に停止" : "停止を受信していません")
                            if let start = record.receivedStart, let end = record.receivedEnd {
                                Text("受信 \(time(start)) — \(time(end))")
                                    .font(.system(.subheadline).monospacedDigit()).foregroundStyle(TraceStyle.green)
                            }
                        }
                        if record.snapshots.isEmpty {
                            Text("この日の全体画像なし").font(.caption).foregroundStyle(TraceStyle.muted)
                        } else {
                            ScrollView(.horizontal) {
                                HStack(spacing: 12) {
                                    ForEach(record.snapshots, id: \.sha) { item in
                                        VStack(alignment: .leading, spacing: 6) {
                                            WorkThumbnail(url: imageURL(HistorySnapshot(sid: record.sid, item: item)), compact: true, crop: item.rect)
                                                .frame(width: 150)
                                            Text(TraceDate.time(item.frameTime)).font(.system(.caption2).monospacedDigit())
                                                .foregroundStyle(TraceStyle.muted)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }.padding(28)
        }
        .background { TraceBackground() }
        .foregroundStyle(TraceStyle.text)
        .navigationTitle(day.date.formatted(.dateTime.year().month().day().locale(TraceDate.locale)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } } }
    }

    private func imageURL(_ snap: HistorySnapshot?) -> URL? {
        guard let snap, let store else { return nil }
        return store.directory(.images, sid: snap.sid).appendingPathComponent("\(snap.item.sha).jpg")
    }

    private func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(TraceDate.locale))
    }
}
