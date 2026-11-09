import SwiftUI
import TraceKit

struct ContentView: View {
    @StateObject private var library: LibraryModel
    @AppStorage("profile.displayName") private var displayName = ""
    @AppStorage("appearance.ordered") private var ordered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var path: [String] = []
    @State private var showProfile = false
    @State private var showNewWork = false

    init() {
        #if DEBUG
        _library = StateObject(wrappedValue: GalleryPreview.enabled ? GalleryPreview.makeLibrary() : LibraryModel())
        _displayName = AppStorage(wrappedValue: "", "profile.displayName", store: GalleryPreview.enabled ? GalleryPreview.defaults : .standard)
        _ordered = AppStorage(wrappedValue: false, "appearance.ordered", store: GalleryPreview.enabled ? GalleryPreview.defaults : .standard)
        #else
        _library = StateObject(wrappedValue: LibraryModel())
        #endif
    }

    var body: some View {
        // 【T15d】Developer タブは消した（画面はギャラリーと作品だけ）。録画拡張の broadcast.debug は残す
        NavigationStack(path: $path) {
            GalleryView(library: library, displayName: displayName, openProfile: { showProfile = true },
                        createWork: { showNewWork = true }, openWork: { path.append($0) })
                .navigationDestination(for: String.self) { id in
                    if let work = library.works.first(where: { $0.workId == id }) {
                        WorkDetailView(work: work, library: library)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("表示名を変更", systemImage: "person.crop.circle") { showProfile = true }
                            Toggle("整列して表示", isOn: $ordered)
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.title3)
                        }
                        .accessibilityLabel("ギャラリーのメニュー")
                    }
                }
        }
        .preferredColorScheme(.dark)
        .tint(TraceStyle.green)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .environment(\.traceOrdered, ordered || reduceMotion || dynamicTypeSize.isAccessibilitySize)
        .sheet(isPresented: $showProfile) {
            // 【11/8】表示名はアカウント（受付API の accounts）にも保存する
            ProfileSheet(displayName: $displayName) { name in Task { await library.saveProfile(displayName: name) } }
                .interactiveDismissDisabled(displayName.isEmpty)
        }
        .sheet(isPresented: $showNewWork) {
            NewWorkSheet(library: library, displayName: displayName) { work in path.append(work.workId) }
        }
        .task {
            if displayName.isEmpty { showProfile = true }
            await library.load()
            await library.saveProfile(displayName: displayName)
        }
    }
}

private struct GalleryView: View {
    @ObservedObject var library: LibraryModel
    let displayName: String
    let openProfile: () -> Void
    let createWork: () -> Void
    let openWork: (String) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var scope = 0

    private var filtered: [WorkDetail] {
        library.works.filter {
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
                && (scope == 0 || (scope == 1 ? $0.status != "finalized" : $0.status == "finalized"))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                masthead
                galleryTools
                if let message = library.errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        InlineNotice(text: message, isError: true)
                        if library.offline && !library.works.isEmpty {
                            Text("保存済みの一覧を表示しています").font(.caption).foregroundStyle(TraceStyle.muted)
                        }
                        Button("もう一度読み込む") { Task { await library.load() } }
                    }
                }
                if library.works.isEmpty && library.loading {
                    ProgressView("作品を読み込んでいます").frame(maxWidth: .infinity, minHeight: 300)
                } else if library.works.isEmpty {
                    ContentUnavailableView {
                        Label("作品なし", systemImage: "rectangle.stack.badge.plus")
                    } actions: {
                        Button("新しい作品", action: newWork).buttonStyle(.borderedProminent).foregroundStyle(TraceStyle.onGreen)
                    }.frame(minHeight: 380)
                } else if filtered.isEmpty {
                    ContentUnavailableView("作品が見つかりません", systemImage: "magnifyingglass")
                } else {
                    WorkGallery(works: filtered, store: library.store, openWork: openWork)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: 1040)
            .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .background { TraceBackground() }
        .foregroundStyle(TraceStyle.text)
        .refreshable { await library.load() }
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard scenePhase == .active else { continue }
                if library.works.contains(where: { $0.status == "recording" || $0.status == "draft" }) {
                    await library.load()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await library.load() } }
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                TraceBrand(size: 52, iconSize: 66)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    galleryTitle
                    Spacer(minLength: 12)
                    newWorkButton
                }
                VStack(alignment: .leading, spacing: 16) { galleryTitle; newWorkButton }
            }
        }
    }

    // 【11/8】左の縦棒はやめた
    private var galleryTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("WORKS").font(.caption2.weight(.semibold))
                .tracking(2).foregroundStyle(TraceStyle.muted)
            Text("作品ギャラリー").font(.title3.weight(.semibold))
        }
    }

    private var newWorkButton: some View {
        Button(action: newWork) {
            Label("新しい作品", systemImage: "plus")
                .font(.subheadline.weight(.semibold)).foregroundStyle(TraceStyle.onGreen)
                .padding(.horizontal, 18).frame(minHeight: 46)
                .background(TraceStyle.green, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(TraceButtonStyle())
    }

    private var galleryTools: some View {
        VStack(spacing: 18) {
            // 【11/8】全て／制作中／提出済み。ボタンを大きくし、四角で囲む
            HStack(spacing: 12) {
                ForEach(Array(["全て", "制作中", "提出済み"].enumerated()), id: \.offset) { index, title in
                    let selected = scope == index
                    Button { scope = index } label: {
                        Text(title).font(.title2.weight(.semibold))
                            .foregroundStyle(selected ? TraceStyle.text : TraceStyle.muted)
                            .padding(.horizontal, 28).frame(minHeight: 64)
                            .background(selected ? TraceStyle.mint : TraceStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? TraceStyle.green : TraceStyle.line, lineWidth: selected ? 2 : 1))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
                }
                Spacer()
                Image(systemName: "arrow.down").font(.caption)
                Text("新しい順").font(.caption)
            }.foregroundStyle(TraceStyle.muted)
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(TraceStyle.muted)
                TextField("タイトルで探す", text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button("クリア") { search = "" }.font(.caption) }
            }
            .padding(.horizontal, 16).frame(minHeight: 46)
            .background(TraceStyle.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TraceStyle.line))
        }
    }

    private func newWork() { displayName.isEmpty ? openProfile() : createWork() }
}

private struct WorkGallery: View {
    let works: [WorkDetail]
    let store: AppGroupStore?
    let openWork: (String) -> Void
    @Environment(\.traceOrdered) private var ordered
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if ordered || sizeClass == .compact {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 28)], alignment: .leading, spacing: 36) {
                ForEach(Array(works.enumerated()), id: \.element.workId) { index, work in card(work, index: index) }
            }
        } else {
            HStack(alignment: .top, spacing: 26) {
                VStack(spacing: 32) {
                    ForEach(Array(works.indices).filter { $0.isMultiple(of: 2) }, id: \.self) { index in
                        card(works[index], index: index)
                    }
                }.frame(maxWidth: .infinity)
                VStack(spacing: 32) {
                    ForEach(Array(works.indices).filter { !$0.isMultiple(of: 2) }, id: \.self) { index in
                        card(works[index], index: index)
                    }
                }.frame(maxWidth: .infinity).padding(.top, 22)
            }
        }
    }

    private func card(_ work: WorkDetail, index: Int) -> some View {
        Button { openWork(work.workId) } label: {
            GalleryWorkCard(work: work, snapshot: work.snapshot(store: store))
        }
        .buttonStyle(TraceButtonStyle())
        .accessibilityIdentifier("work.\(work.workId)")
        .accessibilitySortPriority(Double(works.count - index))
    }
}

private struct GalleryWorkCard: View {
    let work: WorkDetail
    let snapshot: SnapshotRef?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkThumbnail(url: snapshot?.url, emptyText: "全体画像なし", crop: snapshot?.crop)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(work.title).font(.title3.weight(.semibold)).lineLimit(2).foregroundStyle(TraceStyle.text)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(TraceStyle.green)
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        workDate
                        Spacer(minLength: 4)
                        WorkStatusBadge(work: work)
                    }
                    VStack(alignment: .leading, spacing: 8) { workDate; WorkStatusBadge(work: work) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var workDate: some View {
        Text(TraceDate.date(work.createdAt)).font(.caption).foregroundStyle(TraceStyle.muted)
    }
}

private struct ProfileSheet: View {
    @Binding var displayName: String
    var saved: (String) -> Void = { _ in }
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("表示名", text: $name).textContentType(.nickname)
                }
                Section {
                    Button {
                        displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved(displayName)
                        dismiss()
                    } label: { Label("保存", systemImage: "checkmark") }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 50)
                }
            }
            .navigationTitle("表示名")
            .onAppear { name = displayName }
            .toolbar {
                if !displayName.isEmpty { Button("閉じる") { dismiss() } }
            }
        }.presentationDetents([.medium]).preferredColorScheme(.dark).tint(TraceStyle.green)
    }
}

private struct NewWorkSheet: View {
    @ObservedObject var library: LibraryModel
    let displayName: String
    let created: (WorkDetail) -> Void
    @State private var title = ""
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("作品のタイトル") {
                    TextField("タイトル", text: $title)
                    Label(displayName, systemImage: "person.crop.circle").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = library.errorMessage { Text(error).foregroundStyle(.orange) }
                Button {
                    busy = true
                    Task {
                        if let work = await library.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines), displayName: displayName) {
                            dismiss()
                            created(work)
                        }
                        busy = false
                    }
                } label: {
                    if busy { ProgressView() } else { Label("作成", systemImage: "plus") }
                }.disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 100)
            }
            .navigationTitle("新しい作品")
            .toolbar { Button("キャンセル") { dismiss() }.disabled(busy) }
        }.presentationDetents([.medium]).interactiveDismissDisabled(busy).preferredColorScheme(.dark).tint(TraceStyle.green)
    }
}

#Preview { ContentView() }
