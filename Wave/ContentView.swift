import SwiftUI
import WebKit
import Combine
import UniformTypeIdentifiers

// MARK: - Models

final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let containerFolder: URL
    
    @Published var title: String
    @Published var url: URL?
    @Published var addressFieldText: String = ""
    @Published var preview: NSImage?
    
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
        webView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)
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

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "URL", let webView = object as? WKWebView {
            DispatchQueue.main.async {
                self.url = webView.url
                self.addressFieldText = webView.url?.absoluteString ?? ""
            }
        }
    }
    
    func close() {
        guard let webView = webView else { return }

        // Stop everything and load blank page
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))

        // Clear delegates
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        
        webView.removeFromSuperview()
        self.webView = nil
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
            .appendingPathComponent("BrowserContainers")
        let folder = baseFolder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let store = WKWebsiteDataStore.default()

        let tab = BrowserTab(title: "New Tab", url: nil, dataStore: store, containerFolder: folder)
        return TabContainer(name: name, tabs: [tab], folderURL: folder, dataStore: store)
    }
}

struct TabReorderDelegate: DropDelegate {
    @Binding var containers: [TabContainer]
    let containerIndex: Int
    let current: BrowserTab
    let currentIndex: Int
    @Binding var selectedTabIndex: Int
    
    func performDrop(info: DropInfo) -> Bool { true }
    
    func dropEntered(info: DropInfo) {
        guard
            let item = info.itemProviders(for: [UTType.plainText]).first
        else { return }

        item.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
            guard
                let d = data as? Data,
                let str = String(data: d, encoding: .utf8),
                let draggedID = UUID(uuidString: str),
                let fromIndex = containers[containerIndex].tabs.firstIndex(where: { $0.id == draggedID }),
                fromIndex != currentIndex
            else { return }

            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    let tab = containers[containerIndex].tabs.remove(at: fromIndex)
                    containers[containerIndex].tabs.insert(tab, at: currentIndex)

                    if selectedTabIndex == fromIndex { selectedTabIndex = currentIndex }
                    else if selectedTabIndex >= min(fromIndex, currentIndex)
                            && selectedTabIndex <= max(fromIndex, currentIndex) {
                        if fromIndex < currentIndex { selectedTabIndex -= 1 }
                        else { selectedTabIndex += 1 }
                    }
                }
            }
        }
    }
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
            for tab in container.tabs {
                tab.saveTabStateSync()
            }
        }
    }
    
    static func loadContainers() -> [TabContainer] {
        let baseFolder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrowserContainers")
        
        guard let folderNames = try? FileManager.default.contentsOfDirectory(atPath: baseFolder.path) else { return [] }
        
        return folderNames.compactMap { name in
            let folder = baseFolder.appendingPathComponent(name)
            let store = WKWebsiteDataStore.default()
            
            let tabFiles = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".json") } ?? []
            let tabs = tabFiles.compactMap { fileName -> BrowserTab? in
                let fileURL = folder.appendingPathComponent(fileName)
                guard
                    let data = try? Data(contentsOf: fileURL),
                    let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let urlString = dict["url"] as? String,
                    let url = URL(string: urlString)
                else { return nil }
                
                let title = dict["title"] as? String ?? "New Tab"
                
                return BrowserTab(title: title, url: url, dataStore: store, containerFolder: folder)
            }
            
            return TabContainer(name: name, tabs: tabs, folderURL: folder, dataStore: store)
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
                EmptyView()
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
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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
                        .frame(minWidth: 80)
                        .onDrag {
                            let provider = NSItemProvider()
                            let idString = tab.id.uuidString

                            provider.registerDataRepresentation(
                                forTypeIdentifier: UTType.plainText.identifier,
                                visibility: .all
                            ) { completion in
                                Task { @MainActor in
                                    completion(idString.data(using: .utf8), nil)
                                }
                                return nil
                            }

                            return provider
                        }
                        .onDrop(
                            of: [.text],
                            delegate: TabReorderDelegate(
                                containers: $containers,
                                containerIndex: selectedContainerIndex,
                                current: tab,
                                currentIndex: offset,
                                selectedTabIndex: $selectedTabIndex
                            )
                        )
                    }
                    Button(action: addTab) {
                        Image(systemName: "plus")
                            .font(.system(size: 16))
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.black)
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(.white)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: containers[selectedContainerIndex].tabs.count)
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
                                    Image(nsImage: image)
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
                    .background(Color(NSColor.windowBackgroundColor))
                }
                Spacer()
                Button(action: { withAnimation(.spring()){ showingTabOverview.toggle() } }) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 18))
                }
            }
            .padding()
            .buttonStyle(PlainButtonStyle())
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

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            containers[selectedContainerIndex].tabs.remove(at: index)

            // Ensure there's always at least one tab
            if containers[selectedContainerIndex].tabs.isEmpty {
                addTab()
                selectedTabIndex = 0
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

struct WebViewContainer: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = tab.webView!
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }

    class Coordinator: NSObject, WKNavigationDelegate {
        var tab: BrowserTab
        init(tab: BrowserTab) { self.tab = tab }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.tab.url = webView.url
                self.tab.addressFieldText = webView.url?.absoluteString ?? ""
                if let title = webView.title, !title.isEmpty {
                    self.tab.title = title
                }

                let config = WKSnapshotConfiguration()
                config.afterScreenUpdates = true
                webView.takeSnapshot(with: config) { image, _ in
                    if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        self.tab.preview = NSImage(cgImage: cgImage, size: NSSize(width: 400, height: 300))
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if let scheme = url.scheme?.lowercased(), ["http", "https", "about"].contains(scheme) {
                decisionHandler(.allow)
            } else { decisionHandler(.cancel) }
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
            ZStack(alignment: .center) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue.opacity(0.8))
                        .matchedGeometryEffect(id: "tabHighlight", in: namespace)
                        .frame(height: 28)
                }
                HStack(spacing: 6) {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Button(action: closeAction) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                    }
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
                if !isEditing {
                    if tab.addressFieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        tab.addressFieldText = tab.url?.absoluteString ?? tab.url?.absoluteString ?? ""
                    }
                }
            },
            onCommit: commit
        )
        .textFieldStyle(RoundedBorderTextFieldStyle())
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
