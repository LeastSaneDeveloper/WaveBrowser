#if os(macOS)
import AppKit
import SwiftUI
typealias PlatformImage = NSImage
typealias PlatformViewRepresentable = NSViewRepresentable
typealias PlatformColor = NSColor
#elseif os(iOS)
import UIKit
import SwiftUI
typealias PlatformImage = UIImage
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformColor = UIColor
#endif
import WebKit
import Combine
import UniformTypeIdentifiers

// MARK: Site Identifier

extension URL {
    var siteIdentifier: String? {
        host?.lowercased()
    }
}

// MARK: Per-site Datastore

final class SiteDataStoreManager {
    static var stores: [String: WKWebsiteDataStore] = [:]

    static func store(for url: URL?) -> WKWebsiteDataStore {
        guard let url = url, let site = url.siteIdentifier else {
            return WKWebsiteDataStore.default()
        }
        if let existing = stores[site] { return existing }
        let newStore = WKWebsiteDataStore.default()
        stores[site] = newStore
        return newStore
    }
}

// MARK: - Browser Tab

final class BrowserTab: NSObject, ObservableObject, Identifiable {
    var id: UUID = UUID()
    let groupFolder: URL
    
    @Published var title: String
    @Published var url: URL?
    @Published var addressFieldText: String = ""
    @Published var preview: PlatformImage?
    
    var webView: WKWebView?

    init(title: String = "New Tab", url: URL? = nil, groupFolder: URL) {
        self.title = title
        self.url = url
        self.addressFieldText = url?.absoluteString ?? ""
        self.groupFolder = groupFolder
        super.init()

        let storeToUse = SiteDataStoreManager.store(for: url)

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = storeToUse

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
        self.webView = webView

        if let initialURL = url {
            webView.load(URLRequest(url: initialURL))
        }
    }

    func load(url: URL) {
        self.url = url
        self.addressFieldText = url.absoluteString
        webView?.load(URLRequest(url: url))
    }
    
    func close() {
        guard let webView = webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
    }
    
    func deleteTabFile() {
        let fileURL = groupFolder.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    deinit {
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
    }

    func saveTabState() async throws {
        guard let webView = webView else { return }
        let state: [String: Any] = [
            "url": self.url?.absoluteString ?? "",
            "title": title
        ]
        let fileURL = groupFolder.appendingPathComponent("\(self.id.uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: state)
        try data.write(to: fileURL)
    }
    
    func saveTabStateSync() {
        guard let webView = webView else { return }
        let state: [String: Any] = [
            "url": self.url?.absoluteString ?? "",
            "title": title
        ]
        let fileURL = groupFolder.appendingPathComponent("\(self.id.uuidString).json")
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: fileURL)
        }
    }
    
    func persistState() {
        Task {
            try? await saveTabState()
        }
    }
}

extension BrowserTab {
    convenience init?(fromFile fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        
        let id = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent) ?? UUID()
        let title = dict["title"] as? String ?? "New Tab"
        let url = (dict["url"] as? String).flatMap { URL(string: $0) }
        
        self.init(title: title, url: url, groupFolder: fileURL.deletingLastPathComponent())
        self.id = id
    }
}

// MARK: - Tab Group (per site isolation)

struct TabGroup: Identifiable {
    let id = UUID()
    var name: String
    var tabs: [BrowserTab]
    var folderURL: URL
}

struct TabGroupsManager {
    static let baseFolder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WaveData")
        .appendingPathComponent("TabGroups")

    static func saveGroups(_ groups: [TabGroup]) {
        try? FileManager.default.createDirectory(at: baseFolder, withIntermediateDirectories: true)

        for group in groups {
            group.saveAllTabs()
        }

        let summary = groups.map { ["name": $0.name, "folder": $0.folderURL.path] }
        let fileURL = baseFolder.appendingPathComponent("groups.json")
        if let data = try? JSONSerialization.data(withJSONObject: summary) {
            try? data.write(to: fileURL)
        }
    }

    static func loadGroups() -> [TabGroup] {
        let fileURL = baseFolder.appendingPathComponent("groups.json")
        guard let data = try? Data(contentsOf: fileURL),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [] }

        var groups: [TabGroup] = []
        for dict in array {
            guard let folderPath = dict["folder"] else { continue }
            let folderURL = URL(fileURLWithPath: folderPath)
            let files = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
            let tabs = files.compactMap { BrowserTab(fromFile: $0) }
            if !tabs.isEmpty {
                let group = TabGroup(name: dict["name"] ?? "Group", tabs: tabs, folderURL: folderURL)
                groups.append(group)
            }
        }
        return groups
    }
}

extension TabGroup {
    static func create(for url: URL? = nil, name: String? = nil) -> TabGroup {
        let domain = url?.host ?? "DefaultGroup"
        let groupName = name ?? domain
        let baseFolder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WaveData")
            .appendingPathComponent("TabGroups")
            .appendingPathComponent(domain)

        try? FileManager.default.createDirectory(at: baseFolder, withIntermediateDirectories: true)

        let initialTab = BrowserTab(title: "New Tab", url: url, groupFolder: baseFolder)

        return TabGroup(name: groupName, tabs: [initialTab], folderURL: baseFolder)
    }
    
    func saveAllTabs() {
        for tab in tabs {
            tab.saveTabStateSync()
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @State private var tabGroups: [TabGroup] = []
    @State private var selectedGroupIndex: Int = 0
    @State private var selectedTabIndex: Int = 0
    @State private var showingTabOverview = false
    @State private var showingSettings = false
    @State private var showingNewGroupPopover = false
    @State private var newGroupName = ""
    @State private var searchQuery: String = ""

    @Namespace private var tabNamespace

    private let MAX_TAB_WIDTH: CGFloat = 180
    private let MIN_TAB_WIDTH: CGFloat = 80
    private let TAB_SPACING: CGFloat = 6

    // MARK: - Safe Current Tab
    private var currentTab: BrowserTab? {
        guard tabGroups.indices.contains(selectedGroupIndex),
              tabGroups[selectedGroupIndex].tabs.indices.contains(selectedTabIndex) else { return nil }
        return tabGroups[selectedGroupIndex].tabs[selectedTabIndex]
    }

    var body: some View {
        ZStack {
            if !showingTabOverview {
                VStack(spacing: 0) {
                    topBar
                    Divider().background(Color.gray.opacity(0.4))
                    tabsBar
                    Divider().background(Color.gray.opacity(0.4))
                    if let tab = currentTab {
                        WebViewContainer(tab: tab)
                            .id(tab.id)
                    }
                }
                .transition(.move(edge: .bottom))
            } else {
                tabOverview
            }
        }
        .background(Color.black)
        .accentColor(.white)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onAppear {
            let restoredGroups = TabGroupsManager.loadGroups()
            if !restoredGroups.isEmpty {
                tabGroups = restoredGroups
                selectedGroupIndex = 0
                selectedTabIndex = 0
            } else {
                loadTabGroups() // fallback if no saved session
            }
        }
    }

    // MARK: - Load Tab Groups
    private func loadTabGroups() {
        // Ensure at least one TabGroup exists
        if tabGroups.isEmpty {
            let defaultGroup = TabGroup.create(name: "Tabs")
            tabGroups = [defaultGroup]
            selectedGroupIndex = 0
            selectedTabIndex = 0
        }

        // Ensure the "tabs" group exists
        if !tabGroups.contains(where: { $0.name == "Tabs" }) {
            let newTabsGroup = TabGroup.create(name: "Tabs")
            tabGroups.insert(newTabsGroup, at: 0)
            selectedGroupIndex = 0
            selectedTabIndex = 0
        }

        // Ensure the selected group's tabs array is not empty
        if tabGroups[selectedGroupIndex].tabs.isEmpty {
            let newTab = BrowserTab(title: "New Tab", url: nil, groupFolder: tabGroups[selectedGroupIndex].folderURL)
            tabGroups[selectedGroupIndex].tabs = [newTab]
            selectedTabIndex = 0
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: goBack) { Image(systemName: "chevron.left").font(.system(size: 15)) }
            Button(action: goForward) { Image(systemName: "chevron.right").font(.system(size: 15)) }

            HStack(spacing: 6) {
                Button(action: reload) { Image(systemName: "arrow.clockwise").font(.system(size: 15)) }
                if let tab = currentTab {
                    WebAddressField(tab: tab)
                        .id(tab.id)
                        .frame(width: 300)
                }
                Button(action: {}) {
                    Image(systemName: "shield.lefthalf.fill").font(.system(size: 16)).foregroundColor(.green)
                }
            }.frame(maxWidth: .infinity)

            Button(action: { withAnimation(.spring()){ showingTabOverview.toggle() } }) {
                Image(systemName: "square.grid.2x2").font(.system(size: 18))
            }

            Menu {
                Button("History") {}
                Button("Bookmarks") {}
                Button("Downloads") {}
                Button("Clear data & close tabs") { }
                Divider()
                Button("Settings") { showingSettings.toggle() }
            } label: {
                #if os(macOS)
                EmptyView()
                #elseif os(iOS)
                Image(systemName: "line.horizontal.3")
                #endif
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.black)
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(.white)
    }

    // MARK: - Tabs Bar
    private var tabsBar: some View {
        GeometryReader { geometry in
            HStack(spacing: TAB_SPACING) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TAB_SPACING) {
                        if tabGroups.indices.contains(selectedGroupIndex) {
                            let tabs = tabGroups[selectedGroupIndex].tabs
                            let tabCount = CGFloat(tabs.count)
                            let plusButtonWidth: CGFloat = 20
                            let totalFixedSpace: CGFloat = 32 + plusButtonWidth + TAB_SPACING
                            let availableWidthForTabs = geometry.size.width - totalFixedSpace
                            let totalSpacingBetweenTabs = tabCount > 0 ? (tabCount - 1) * TAB_SPACING : 0
                            let idealWidth = tabCount > 0 ? (availableWidthForTabs - totalSpacingBetweenTabs) / tabCount : MAX_TAB_WIDTH
                            let tabWidth: CGFloat = min(MAX_TAB_WIDTH, max(MIN_TAB_WIDTH, idealWidth))

                            ForEach(Array(tabs.enumerated()), id: \.element.id) { offset, tab in
                                TabButton(tab: tab,
                                          isSelected: offset == selectedTabIndex,
                                          namespace: tabNamespace,
                                          closeAction: { closeTab(at: offset) }) {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        selectedTabIndex = offset
                                    }
                                }
                                .frame(width: tabWidth)
                            }

                            Button(action: addTab) { Image(systemName: "plus").font(.system(size: 16)) }
                                .frame(width: plusButtonWidth)
                        }
                    }
                    .frame(minWidth: geometry.size.width - 32 - TAB_SPACING, alignment: .leading)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.black)
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(.white)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: tabGroups.indices.contains(selectedGroupIndex) ? tabGroups[selectedGroupIndex].tabs.count : 0)
        }
        .frame(height: 40)
    }

    // MARK: - Tab Overview
    private var tabOverview: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                TextField("Search \(tabGroups[selectedGroupIndex].name)...", text: $searchQuery)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            #if os(macOS)
                            .fill(Color(NSColor.windowBackgroundColor))
                            #elseif os(iOS)
                            .fill(Color(UIColor.black))
                            #endif
                    )
                    .foregroundColor(.white)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.5), lineWidth: 1))
                    .frame(width: 300)
                Spacer()
            }.padding(.top)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 20)], spacing: 20) {
                    ForEach(filteredTabs.indices, id: \.self) { index in
                        ZStack(alignment: .topTrailing) {
                            VStack(spacing: 6) {
                                if let image = filteredTabs[index].preview {
                                    #if os(macOS)
                                    Image(nsImage: image).resizable().scaledToFill().frame(height: 120).clipped().cornerRadius(8)
                                    #elseif os(iOS)
                                    Image(uiImage: image).resizable().scaledToFill().frame(height: 120).clipped().cornerRadius(8)
                                    #endif
                                } else {
                                    Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 120).cornerRadius(8)
                                        .overlay(Text("Loading...").foregroundColor(.white.opacity(0.7)))
                                }
                                Text(filteredTabs[index].title).font(.headline).foregroundColor(.white).lineLimit(1).multilineTextAlignment(.center)
                            }
                            Button(action: {
                                if let actualIndex = tabGroups[selectedGroupIndex].tabs.firstIndex(where: { $0.id == filteredTabs[index].id }) {
                                    closeTab(at: actualIndex)
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.white).background(Color.black.opacity(0.6)).clipShape(Circle()).font(.system(size: 14))
                            }.buttonStyle(PlainButtonStyle()).padding(4)
                        }
                        .onTapGesture {
                            if let actualIndex = tabGroups[selectedGroupIndex].tabs.firstIndex(where: { $0.id == filteredTabs[index].id }) {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    selectedTabIndex = actualIndex
                                    showingTabOverview.toggle()
                                }
                            }
                        }
                    }
                }.padding()
            }

            Divider().background(Color.gray.opacity(0.4))

            HStack(spacing: 6) {
                ForEach(tabGroups.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Text(tabGroups[i].name)
                            .font(.system(size: 14, weight: i == selectedGroupIndex ? .bold : .regular))
                            .foregroundColor(i == selectedGroupIndex ? .white : .gray)
                            .onTapGesture { withAnimation(.spring()) { selectedGroupIndex = i } }
                        if tabGroups.count > 1 {
                            Button(action: { removeGroup(at: i) }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.white).font(.system(size: 12))
                            }.buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                Button(action: { showingNewGroupPopover = true }) {
                    Image(systemName: "plus").font(.system(size: 16))
                }.popover(isPresented: $showingNewGroupPopover) {
                    VStack(spacing: 12) {
                        Text("New Tab Group").font(.headline).padding(.top)
                        TextField("Group Name", text: $newGroupName).textFieldStyle(RoundedBorderTextFieldStyle()).padding(.horizontal)
                        HStack {
                            Button("Cancel") { showingNewGroupPopover = false }
                            Spacer()
                            Button("Create") {
                                addGroup(named: newGroupName)
                                showingNewGroupPopover = false
                                newGroupName = ""
                            }.disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }.padding()
                    }.frame(width: 250)
                    #if os(macOS)
                    .background(Color(NSColor.windowBackgroundColor))
                    #elseif os(iOS)
                    .background(Color(UIColor.systemBackground))
                    #endif
                }
                Spacer()
                Button(action: { withAnimation(.spring()){ showingTabOverview.toggle() } }) { Image(systemName: "square.grid.2x2").font(.system(size: 18)) }
            }
            .padding()
            #if os(macOS)
            .buttonStyle(PlainButtonStyle())
            #elseif os(iOS)
            .buttonStyle(.plain)
            #endif
            .foregroundColor(.white)
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
    }

    // MARK: Filtered Tabs
    private var filteredTabs: [BrowserTab] {
        let allTabs = tabGroups[selectedGroupIndex].tabs
        if searchQuery.isEmpty { return allTabs }
        return allTabs.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) }
    }

    // MARK: Actions
    private func goBack() { currentTab?.webView?.goBack() }
    private func goForward() { currentTab?.webView?.goForward() }
    private func reload() { currentTab?.webView?.reload() }

    private func addTab() {
        withAnimation(.spring()) {
            let newTab = BrowserTab(
                title: "New Tab",
                url: nil, // no initial URL
                groupFolder: tabGroups[selectedGroupIndex].folderURL
            )

            tabGroups[selectedGroupIndex].tabs.append(newTab)
            TabGroupsManager.saveGroups(tabGroups)
            selectedTabIndex = tabGroups[selectedGroupIndex].tabs.count - 1
            newTab.persistState()
        }
    }

    private func closeTab(at index: Int) {
        guard tabGroups.indices.contains(selectedGroupIndex),
              tabGroups[selectedGroupIndex].tabs.indices.contains(index) else { return }

        let tab = tabGroups[selectedGroupIndex].tabs[index]
        Task { try? await tab.saveTabState() }
        tab.close()
        tab.deleteTabFile()
        TabGroupsManager.saveGroups(tabGroups)

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            tabGroups[selectedGroupIndex].tabs.remove(at: index)
            if tabGroups[selectedGroupIndex].tabs.isEmpty {
                addTab()
            } else if selectedTabIndex >= tabGroups[selectedGroupIndex].tabs.count {
                selectedTabIndex = tabGroups[selectedGroupIndex].tabs.count - 1
            } else if selectedTabIndex > index {
                selectedTabIndex -= 1
            } else if selectedTabIndex == index {
                selectedTabIndex = max(0, index - 1)
            }
        }
    }

    private func addGroup(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        withAnimation(.spring()) {
            let newGroup = TabGroup.create(name: trimmed)
            tabGroups.append(newGroup)
            TabGroupsManager.saveGroups(tabGroups)
            selectedGroupIndex = tabGroups.count - 1
            selectedTabIndex = 0
        }
    }

    private func removeGroup(at index: Int) {
        withAnimation(.spring()) {
            tabGroups.remove(at: index)
            TabGroupsManager.saveGroups(tabGroups)
            if selectedGroupIndex >= tabGroups.count {
                selectedGroupIndex = max(tabGroups.count - 1, 0)
            }
        }
    }

    private func clearDataAndCloseTabs() {
        withAnimation(.spring()) {
            tabGroups = [TabGroup.create()]
            TabGroupsManager.saveGroups(tabGroups)
            selectedGroupIndex = 0
            selectedTabIndex = 0
        }
    }
}

// MARK: - WebViewContainer

struct WebViewContainer: PlatformViewRepresentable {
    @ObservedObject var tab: BrowserTab

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        let webView = tab.webView!
        webView.navigationDelegate = context.coordinator
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    #elseif os(iOS)
    func makeUIView(context: Context) -> WKWebView {
        guard let webView = tab.webView else {
            let config = WKWebViewConfiguration()
            config.preferences.javaScriptCanOpenWindowsAutomatically = true
            let newWebView = WKWebView(frame: .zero, configuration: config)
            tab.webView = newWebView
            return newWebView
        }
        webView.navigationDelegate = context.coordinator
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    #endif

    class Coordinator: NSObject, WKNavigationDelegate {
        var tab: BrowserTab
        init(tab: BrowserTab) { self.tab = tab }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.tab.url = webView.url
                self.tab.addressFieldText = webView.url?.absoluteString ?? ""
                if let title = webView.title, !title.isEmpty { self.tab.title = title }
                self.tab.persistState()
            }

            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            webView.takeSnapshot(with: config) { image, _ in
                #if os(macOS)
                if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    self.tab.preview = NSImage(cgImage: cgImage, size: NSSize(width: 400, height: 300))
                }
                #elseif os(iOS)
                if let image = image { self.tab.preview = image }
                #endif
            }
        }
    }
}

// MARK: - Tab Button

struct TabButton: View {
    @ObservedObject var tab: BrowserTab
    let isSelected: Bool
    var namespace: Namespace.ID
    let closeAction: () -> Void
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue.opacity(0.8))
                        .matchedGeometryEffect(id: "tabHighlight", in: namespace)
                        .frame(height: 28)
                }

                HStack {
                    Color.clear.frame(width: 20)
                    Spacer()
                    Text(tab.title).font(.system(size: 13, weight: .medium)).foregroundColor(.white).minimumScaleFactor(0.6).lineLimit(1)
                    Spacer()
                    Button(action: closeAction) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.8))
                    }.frame(width: 20).buttonStyle(PlainButtonStyle())
                }.padding(.horizontal, 8).padding(.vertical, 4)
            }
        }.buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Address Field

struct WebAddressField: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        TextField(
            "Search or enter an address...",
            text: $tab.addressFieldText,
            onEditingChanged: { isEditing in
                if !isEditing, tab.addressFieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tab.addressFieldText = tab.url?.absoluteString ?? ""
                }
            },
            onCommit: commit
        )
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                #if os(macOS)
                .fill(Color(NSColor.windowBackgroundColor))
                #elseif os(iOS)
                .fill(Color(UIColor.black))
                #endif
        )
        .foregroundColor(.white)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.5), lineWidth: 1))
    }

    private func commit() {
        let raw = tab.addressFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { tab.addressFieldText = tab.url?.absoluteString ?? ""; return }

        var urlString = raw
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") { urlString = "https://\(urlString)" }
        guard let url = URL(string: urlString), url.host != nil else { return }

        if tab.url != url {
            tab.load(url: url)
            tab.persistState()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        VStack {
            Text("Settings").font(.largeTitle).padding()
            Spacer()
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
