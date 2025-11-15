import SwiftUI
import WebKit
import Combine

// MARK: - Models

final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var url: URL?
    @Published var addressFieldText: String = ""
    @Published var preview: NSImage?

    // Add this line:
    var webView: WKWebView?

    init(title: String = "New Tab", url: URL? = nil) {
        self.title = title
        self.url = url
        self.addressFieldText = url?.absoluteString ?? ""
        super.init()

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = .default()

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
        webView?.load(URLRequest(url: url))  // Ensure the tab’s own webView loads it
    }
}

struct TabContainer: Identifiable {
    let id = UUID()
    var name: String
    var tabs: [BrowserTab]
}

// MARK: - Main View

struct ContentView: View {
    @State private var containers: [TabContainer] = [
        TabContainer(name: "Tabs", tabs: [BrowserTab(title: "New Tab", url: nil)])
    ]
    @State private var activeWebView: WKWebView?
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
                    ForEach(containers[selectedContainerIndex].tabs.indices, id: \.self) { index in
                        TabButton(
                            title: containers[selectedContainerIndex].tabs[index].title,
                            isSelected: index == selectedTabIndex,
                            namespace: tabNamespace,
                            closeAction: { closeTab(at: index) }
                        ) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                selectedTabIndex = index
                            }
                        }
                        .frame(minWidth: 80)
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
        .onAppear(perform: capturePreviews)
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
            let newTab = BrowserTab(title: "New Tab", url: nil)
            containers[selectedContainerIndex].tabs.append(newTab)
            selectedTabIndex = containers[selectedContainerIndex].tabs.count - 1
        }
    }
    
    private func closeTab(at index: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            containers[selectedContainerIndex].tabs.remove(at: index)
            if containers[selectedContainerIndex].tabs.isEmpty {
                addTab()
                selectedTabIndex = 0
            } else if selectedTabIndex >= containers[selectedContainerIndex].tabs.count {
                selectedTabIndex = containers[selectedContainerIndex].tabs.count - 1
            }
        }
    }
    
    private func addContainer(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        withAnimation(.spring()) {
            let newContainer = TabContainer(name: trimmed, tabs: [])
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
            containers = [TabContainer(name: "Tabs", tabs: [BrowserTab(title: "New Tab", url: nil)])]
            selectedContainerIndex = 0
            selectedTabIndex = 0
        }
    }
    
    private func capturePreviews() {
        for i in containers.indices {
            for j in containers[i].tabs.indices {
                activeWebView?.takeSnapshot(with: nil) { image, _ in
                    if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        containers[i].tabs[j].preview = NSImage(cgImage: cgImage, size: NSSize(width: 400, height: 300))
                    }
                }
            }
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
    let title: String
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
                    Text(title)
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
        TextField("Search or enter an address...",
                  text: $tab.addressFieldText,
                  onCommit: commit)
            .textFieldStyle(RoundedBorderTextFieldStyle())
    }

    private func commit() {
        var raw = tab.addressFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            raw = "https://\(raw)"
        }

        guard let url = URL(string: raw), url.host != nil else { return }

        tab.load(url: url)
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
