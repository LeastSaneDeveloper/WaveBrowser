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

// MARK: - Models

final class BrowserTab: NSObject, ObservableObject, Identifiable {
    var id: UUID = UUID()
    let containerFolder: URL
    
    @Published var title: String
    @Published var url: URL?
    @Published var addressFieldText: String = ""
    @Published var preview: PlatformImage?
    
    var webView: WKWebView?

    init(title: String = "New Tab", url: URL? = nil, dataStore: WKWebsiteDataStore, containerFolder: URL) {
        self.title = title
        self.url = url
        self.addressFieldText = url?.absoluteString ?? ""
        self.containerFolder = containerFolder
        super.init()

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = dataStore
        
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
        let fileURL = containerFolder.appendingPathComponent("\(id.uuidString).json")
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
            "url": webView.url?.absoluteString ?? "",
            "title": title
        ]
        let fileURL = containerFolder.appendingPathComponent("\(self.id.uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: state)
        try data.write(to: fileURL)
    }
    
    func saveTabStateSync() {
        guard let webView = webView else { return }
        let state: [String: Any] = [
            "url": webView.url?.absoluteString ?? "",
            "title": title
        ]
        let fileURL = containerFolder.appendingPathComponent("\(self.id.uuidString).json")
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
    convenience init?(fromFile fileURL: URL, dataStore: WKWebsiteDataStore) {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        
        let id = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent) ?? UUID()
        let title = dict["title"] as? String ?? "New Tab"
        let url = (dict["url"] as? String).flatMap { URL(string: $0) }
        
        self.init(title: title, url: url, dataStore: dataStore, containerFolder: fileURL.deletingLastPathComponent())
        self.id = id
    }
}

struct TabContainer: Identifiable {
    let id = UUID()
    var name: String
    var tabs: [BrowserTab]
    var folderURL: URL
    var dataStore: WKWebsiteDataStore
}

extension TabContainer {
    static func create(name: String) -> TabContainer {
        let baseFolder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WaveData")
            .appendingPathComponent("Containers")
        
        let containerFolder = baseFolder.appendingPathComponent(name)
        let websiteDataStoreSubfolder = containerFolder.appendingPathComponent("Cache")
        
        try? FileManager.default.createDirectory(at: containerFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: websiteDataStoreSubfolder, withIntermediateDirectories: true)
        
        let storeID = UUID().uuidString
        let store = WKWebsiteDataStore(forIdentifier: UUID(uuidString: storeID) ?? UUID())
        
        let metadata = ContainerMetadata(storeID: storeID)
        let metadataURL = containerFolder.appendingPathComponent("store.json")
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: metadataURL)
        }
        
        let tab = BrowserTab(title: "New Tab", url: nil, dataStore: store, containerFolder: containerFolder)
        return TabContainer(name: name, tabs: [tab], folderURL: containerFolder, dataStore: store)
    }
}

struct ContainerMetadata: Codable {
    let storeID: String
}

// MARK: - Main View

struct ContentView: View {
    @State private var containers: [TabContainer] = []
    @State private var selectedContainerIndex: Int = 0
    @State private var selectedTabIndex: Int = 0
    @State private var showingTabOverview = false
    @State private var showingSettings = false
    @State private var showingNewContainerPopover = false
    @State private var newContainerName = ""
    @State private var searchQuery: String = ""
    
    @Namespace private var tabNamespace
    
    private let MAX_TAB_WIDTH: CGFloat = 180
    private let MIN_TAB_WIDTH: CGFloat = 80
    private let TAB_SPACING: CGFloat = 6
    
    var body: some View {
        ZStack {
            if !showingTabOverview {
                VStack(spacing: 0) {
                    topBar
                    Divider().background(Color.gray.opacity(0.4))
                    tabsBar
                    Divider().background(Color.gray.opacity(0.4))
                    WebViewContainer(tab: containers[selectedContainerIndex].tabs[selectedTabIndex])
                        .id(containers[selectedContainerIndex].tabs[selectedTabIndex].id)
                }
                .transition(.move(edge: .bottom))
            } else {
                tabOverview
            }
        }
        .background(Color.black)
        .accentColor(.white)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
    
    // MARK: Load Containers
    
    init() {
        let loaded = Self.loadContainers()
        
        if loaded.isEmpty {
            // No saved containers: create a default one
            _containers = State(initialValue: [TabContainer.create(name: "Tabs")])
            _selectedContainerIndex = State(initialValue: 0)
            _selectedTabIndex = State(initialValue: 0)
        } else {
            // Fix containers that have zero tabs
            let fixedContainers = loaded.map { container -> TabContainer in
                var c = container
                if c.tabs.isEmpty {
                    let tab = BrowserTab(
                        title: "New Tab",
                        url: nil,
                        dataStore: c.dataStore,
                        containerFolder: c.folderURL
                    )
                    c.tabs = [tab]
                }
                return c
            }
            _containers = State(initialValue: fixedContainers)
            _selectedContainerIndex = State(initialValue: 0)
            // Ensure selectedTabIndex is valid
            _selectedTabIndex = State(initialValue: fixedContainers[0].tabs.isEmpty ? 0 : 0)
        }
    }
    
    func saveAllTabsSync() {
        for container in containers {
            let folder = container.folderURL
            let existingFiles = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let currentTabIDs = Set(container.tabs.map { $0.id.uuidString + ".json" })
            
            for file in existingFiles where file.hasSuffix(".json") && !currentTabIDs.contains(file) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
            }
            
            for tab in container.tabs {
                tab.saveTabStateSync()
            }
        }
    }
    
    static func loadContainers() -> [TabContainer] {
        let baseFolder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WaveData")
            .appendingPathComponent("Containers")
        
        guard let folderNames = try? FileManager.default.contentsOfDirectory(atPath: baseFolder.path) else { return [] }
        
        return folderNames.compactMap { name in
            let containerFolder = baseFolder.appendingPathComponent(name)
            
            let metadataURL = containerFolder.appendingPathComponent("store.json")
            var storeID: String
            if let data = try? Data(contentsOf: metadataURL),
               let metadata = try? JSONDecoder().decode(ContainerMetadata.self, from: data) {
                storeID = metadata.storeID
            } else {
                storeID = UUID().uuidString
            }
            
            let store = WKWebsiteDataStore(forIdentifier: UUID(uuidString: storeID) ?? UUID())
            
            let tabFiles = (try? FileManager.default.contentsOfDirectory(atPath: containerFolder.path))?.filter { $0.hasSuffix(".json") } ?? []
            let tabs = tabFiles.compactMap { fileName -> BrowserTab? in
                let fileURL = containerFolder.appendingPathComponent(fileName)
                return BrowserTab(fromFile: fileURL, dataStore: store)
            }
            
            let validIDs = Set(tabs.map { $0.id.uuidString + ".json" })
            for file in tabFiles where !validIDs.contains(file) {
                let fileURL = containerFolder.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: fileURL)
            }
            
            return TabContainer(name: name, tabs: tabs, folderURL: containerFolder, dataStore: store)
        }
    }
    
    // MARK: Top Bar
    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15))
            }
            Button(action: goForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15))
            }
            
            HStack(spacing: 6) {
                Button(action: reload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15))
                }
                WebAddressField(tab: containers[selectedContainerIndex].tabs[selectedTabIndex])
                    .id(containers[selectedContainerIndex].tabs[selectedTabIndex].id)
                    .frame(width: 300)
                Button(action: {}) {
                    Image(systemName: "shield.lefthalf.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.green)
                }
            }
            .frame(maxWidth: .infinity)
            
            Button(action: { withAnimation(.spring()){ showingTabOverview.toggle() } }) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18))
            }
            
            Menu {
                Button("History") {}
                Button("Bookmarks") {}
                Button("Downloads") {}
                Button("Clear data & close tabs", role: .destructive) { clearDataAndCloseTabs() }
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
    
    // MARK: Tabs Bar
    private var tabsBar: some View {
        GeometryReader { geometry in
            HStack(spacing: TAB_SPACING) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TAB_SPACING) {

                        let tabCount = CGFloat(containers[selectedContainerIndex].tabs.count)
                        let plusButtonWidth: CGFloat = 20
                        let totalFixedSpace: CGFloat = 32 + plusButtonWidth + TAB_SPACING
                        let availableWidthForTabs = geometry.size.width - totalFixedSpace
                        let totalSpacingBetweenTabs = tabCount > 0 ? (tabCount - 1) * TAB_SPACING : 0
                        let idealWidth = tabCount > 0 ? (availableWidthForTabs - totalSpacingBetweenTabs) / tabCount : MAX_TAB_WIDTH
                        let tabWidth: CGFloat = min(MAX_TAB_WIDTH, max(MIN_TAB_WIDTH, idealWidth))
                        
                        ForEach(Array(containers[selectedContainerIndex].tabs.enumerated()), id: \.element.id) { offset, tab in
                            TabButton(
                                tab: tab,
                                isSelected: offset == selectedTabIndex,
                                namespace: tabNamespace,
                                closeAction: { closeTab(at: offset) }
                            ) {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    selectedTabIndex = offset
                                }
                            }
                            // Apply the calculated dynamic width
                            .frame(width: tabWidth)
                        }
                        
                        Button(action: addTab) {
                            Image(systemName: "plus")
                                .font(.system(size: 16))
                        }
                        .frame(width: plusButtonWidth)
                    }
                    .frame(minWidth: geometry.size.width - 32 - TAB_SPACING, alignment: .leading)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.black)
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(.white)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: containers[selectedContainerIndex].tabs.count)
        }
        .frame(height: 40) // Give the GeometryReader a fixed height, matching the bar's height
    }
    
    // MARK: Tab Overview
    private var tabOverview: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                TextField("Search \(containers[selectedContainerIndex].name)...", text: $searchQuery)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 300)
                Spacer()
            }
            .padding(.top)
            
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 20)], spacing: 20) {
                    ForEach(filteredTabs.indices, id: \.self) { index in
                        ZStack(alignment: .topTrailing) {
                            VStack(spacing: 6) {
                                if let image = filteredTabs[index].preview {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 120)
                                        .clipped()
                                        .cornerRadius(8)
                                } else {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(height: 120)
                                        .cornerRadius(8)
                                        .overlay(Text("Loading...").foregroundColor(.white.opacity(0.7)))
                                }
                                Text(filteredTabs[index].title)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                            
                            Button(action: {
                                if let actualIndex = containers[selectedContainerIndex].tabs.firstIndex(where: { $0.id == filteredTabs[index].id }) {
                                    closeTab(at: actualIndex)
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(Circle())
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(4)
                        }
                        .onTapGesture {
                            if let actualIndex = containers[selectedContainerIndex].tabs.firstIndex(where: { $0.id == filteredTabs[index].id }) {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    selectedTabIndex = actualIndex
                                    showingTabOverview.toggle()
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            
            Divider().background(Color.gray.opacity(0.4))
            
            HStack(spacing: 6) {
                ForEach(containers.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Text(containers[i].name)
                            .font(.system(size: 14, weight: i == selectedContainerIndex ? .bold : .regular))
                            .foregroundColor(i == selectedContainerIndex ? .white : .gray)
                            .onTapGesture {
                                withAnimation(.spring()) { selectedContainerIndex = i }
                            }
                        if containers.count > 1 {
                            Button(action: {
                                removeContainer(at: i)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                Button(action: { showingNewContainerPopover = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16))
                }
                .popover(isPresented: $showingNewContainerPopover) {
                    VStack(spacing: 12) {
                        Text("New Container")
                            .font(.headline)
                            .padding(.top)
                        TextField("Container Name", text: $newContainerName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding(.horizontal)
                        HStack {
                            Button("Cancel") { showingNewContainerPopover = false }
                            Spacer()
                            Button("Create") {
                                addContainer(named: newContainerName)
                                showingNewContainerPopover = false
                                newContainerName = ""
                            }
                            .disabled(newContainerName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding()
                    }
                    .frame(width: 250)
                    #if os(macOS)
                    .background(Color(NSColor.windowBackgroundColor))
                    #elseif os(iOS)
                    .background(Color(UIColor.systemBackground))
                    #endif
                }
                Spacer()
                Button(action: { withAnimation(.spring()){ showingTabOverview.toggle() } }) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 18))
                }
            }
            .padding()
            #if os(macOS)
            .buttonStyle(PlainButtonStyle())
            #elseif os(iOS)
            .buttonStyle(.plain) // iOS 15+ shorthand
            #endif
            .foregroundColor(.white)
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
    }
    
    // MARK: Filtered Tabs
    private var filteredTabs: [BrowserTab] {
        let allTabs = containers[selectedContainerIndex].tabs
        if searchQuery.isEmpty { return allTabs }
        return allTabs.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) }
    }
    
    // MARK: Actions
    private var currentWebView: WKWebView? {
        containers[selectedContainerIndex].tabs[selectedTabIndex].webView
    }

    private func goBack() { currentWebView?.goBack() }
    private func goForward() { currentWebView?.goForward() }
    private func reload() { currentWebView?.reload() }
    
    private func addTab() {
        withAnimation(.spring()) {
            let container = containers[selectedContainerIndex]
            let newTab = BrowserTab(
                title: "New Tab",
                url: nil,
                dataStore: container.dataStore,
                containerFolder: container.folderURL
            )
            containers[selectedContainerIndex].tabs.append(newTab)
            selectedTabIndex = containers[selectedContainerIndex].tabs.count - 1
            newTab.persistState()
        }
    }
    
    private func closeTab(at index: Int) {
        guard containers.indices.contains(selectedContainerIndex),
              containers[selectedContainerIndex].tabs.indices.contains(index) else { return }

        let tab = containers[selectedContainerIndex].tabs[index]
        Task {
            try? await tab.saveTabState()
        }
        tab.close()
        tab.deleteTabFile()

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            containers[selectedContainerIndex].tabs.remove(at: index)

            // Ensure there's always at least one tab
            if containers[selectedContainerIndex].tabs.isEmpty {
                let container = containers[selectedContainerIndex]
                let newTab = BrowserTab(title: "New Tab", url: nil, dataStore: container.dataStore, containerFolder: container.folderURL)
                containers[selectedContainerIndex].tabs.append(newTab)
                selectedTabIndex = 0
                newTab.persistState()
            } else if selectedTabIndex >= containers[selectedContainerIndex].tabs.count {
                // If we closed the last tab, move selection to the previous tab
                selectedTabIndex = containers[selectedContainerIndex].tabs.count - 1
            } else if selectedTabIndex > index {
                // If a tab before the selected tab was removed, adjust the index
                selectedTabIndex -= 1
            } else if selectedTabIndex == index {
                // If we closed the currently selected tab, select the previous one if possible
                selectedTabIndex = max(0, index - 1)
            }
        }
    }
    
    private func addContainer(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        withAnimation(.spring()) {
            let newContainer = TabContainer.create(name: trimmed)
            containers.append(newContainer)
            selectedContainerIndex = containers.count - 1
        }
    }
    
    private func removeContainer(at index: Int) {
        withAnimation(.spring()) {
            containers.remove(at: index)
            if selectedContainerIndex >= containers.count {
                selectedContainerIndex = containers.count - 1
            }
        }
    }
    
    private func clearDataAndCloseTabs() {
        withAnimation(.spring()) {
            let newContainer = TabContainer.create(name: "Tabs")
            containers = [newContainer]
            selectedContainerIndex = 0
            selectedTabIndex = 0
        }
    }
}

// MARK: - WebView

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
                if let image = image {
                    self.tab.preview = image
                }
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
                    Color.clear
                        .frame(width: 20)

                    Spacer()

                    Text(tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)

                    Spacer()

                    // Right close button
                    Button(action: closeAction) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(width: 20)
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .buttonStyle(PlainButtonStyle())
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
                .fill(Color(NSColor.windowBackgroundColor)) // dynamic with system appearance
                #elseif os(iOS)
                .fill(Color(UIColor.black))
                #endif
        )
        .foregroundColor(.primary)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
        )
    }

    private func commit() {
        let raw = tab.addressFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !raw.isEmpty else {
            tab.addressFieldText = tab.url?.absoluteString ?? ""
            return
        }

        var urlString = raw
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://\(urlString)"
        }

        guard let url = URL(string: urlString), url.host != nil else { return }

        if tab.url != url {
            tab.load(url: url)
            tab.persistState()
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        VStack {
            Text("Settings")
                .font(.largeTitle)
                .padding()
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
