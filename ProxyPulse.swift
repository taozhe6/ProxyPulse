import Cocoa
import SwiftUI

// MARK: - Network helpers

class NoRedir: NSObject, URLSessionTaskDelegate {
    func urlSession(_ s: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection r: HTTPURLResponse,
                    newRequest req: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

let probeSess: URLSession = {
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = 8
    return URLSession(configuration: c, delegate: NoRedir(), delegateQueue: nil)
}()

// MARK: - Models

struct IPGeo: Codable {
    let ip: String?; let city: String?; let region: String?
    let country_name: String?; let org: String?; let timezone: String?
}

enum Chk: Equatable { case idle, testing, ok(Int), fail(String), blocked }

struct Site: Identifiable {
    let id = UUID(); let domain: String; let tag: String; var state: Chk = .idle
}

struct ChanStatus: Identifiable {
    let id = UUID()
    let name: String; let icon: String; let note: String
    var ok: Bool?; var detail: String = ""
}

// MARK: - ViewModel

@MainActor
class VM: ObservableObject {
    @Published var myIP: IPGeo?
    @Published var lookupResult: IPGeo?
    @Published var lookupInput = ""
    @Published var expectedEgressIP = ""
    @Published var sites: [Site] = []
    @Published var channels: [ChanStatus] = []
    @Published var fetchingIP = false
    @Published var lookingUp = false
    @Published var testing = false
    @Published var summary = ""
    @Published var ipFailed = false
    @Published var lookupFailed = false
    @Published var showLookup = false

    static let domains: [(String, String)] = [
        ("google.com", "基准"), ("github.com", "基准"),
        ("claude.ai", "Claude"), ("api.anthropic.com", "Claude"),
        ("statsig.anthropic.com", "Claude"), ("sentry.io", "Claude"),
        ("platform.claude.com", "Claude"), ("code.claude.com", "Claude"),
    ]
    static let expectedEgressIPKey = "proxyPulse.expectedEgressIP"

    init() {
        let savedExpected = (UserDefaults.standard.string(forKey: Self.expectedEgressIPKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        expectedEgressIP = savedExpected
        lookupInput = savedExpected
        sites = Self.domains.map { Site(domain: $0.0, tag: $0.1) }
        channels = [
            ChanStatus(name: "网页端", icon: "globe", note: "小火箭管控", ok: nil, detail: "检测中..."),
            ChanStatus(name: "终端", icon: "terminal", note: "env var", ok: nil, detail: "检测中..."),
            ChanStatus(name: "桌面应用", icon: "desktopcomputer", note: "launchctl", ok: nil, detail: "检测中..."),
        ]
        detectChannels()
    }

    func boot() { fetchMyIP(); runTests() }

    func detectChannels() {
        let env = ProcessInfo.processInfo.environment
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let webProxy = Self.sh("scutil --proxy")
            let webOK = webProxy.contains("HTTPEnable : 1") || webProxy.contains("SOCKSEnable : 1")

            let termProxy = env["https_proxy"] ?? env["HTTPS_PROXY"] ?? env["http_proxy"] ?? env["HTTP_PROXY"]
            let termOK = termProxy != nil && !termProxy!.isEmpty

            let lcHTTPS = Self.sh("launchctl getenv https_proxy").trimmingCharacters(in: .whitespacesAndNewlines)
            let lcHTTPSUpper = Self.sh("launchctl getenv HTTPS_PROXY").trimmingCharacters(in: .whitespacesAndNewlines)
            let lcHTTP = Self.sh("launchctl getenv http_proxy").trimmingCharacters(in: .whitespacesAndNewlines)
            let lcHTTPUpper = Self.sh("launchctl getenv HTTP_PROXY").trimmingCharacters(in: .whitespacesAndNewlines)
            let lcProxy = [lcHTTPS, lcHTTPSUpper, lcHTTP, lcHTTPUpper].first(where: { !$0.isEmpty }) ?? ""
            let elecOK = !lcProxy.isEmpty

            let next = [
                ChanStatus(name: "网页端", icon: "globe", note: "小火箭管控",
                           ok: webOK, detail: webOK ? "系统代理已开启" : "系统代理未开启"),
                ChanStatus(name: "终端", icon: "terminal", note: "env var",
                           ok: termOK, detail: termOK ? termProxy! : "未设置 → proxy_on"),
                ChanStatus(name: "桌面应用", icon: "desktopcomputer", note: "launchctl",
                           ok: elecOK, detail: elecOK ? lcProxy : "未设置 → 运行 install.sh"),
            ]

            DispatchQueue.main.async {
                self?.channels = next
            }
        }
    }

    nonisolated private static func sh(_ cmd: String) -> String {
        let p = Process(); let pipe = Pipe()
        p.launchPath = "/bin/bash"; p.arguments = ["-c", cmd]
        p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func fetchMyIP() {
        fetchingIP = true; myIP = nil; ipFailed = false
        Task {
            defer { fetchingIP = false }
            if let g = await geo(nil) { myIP = g } else { ipFailed = true }
        }
    }

    func lookup() {
        let s = lookupInput.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        lookingUp = true; lookupResult = nil; lookupFailed = false
        Task {
            defer { lookingUp = false }
            if let g = await geo(s) { lookupResult = g } else { lookupFailed = true }
        }
    }

    func setExpectedEgressIP(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        expectedEgressIP = value
        lookupInput = value
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.expectedEgressIPKey)
        } else {
            UserDefaults.standard.set(value, forKey: Self.expectedEgressIPKey)
        }
    }

    func prefillLookupFromExpected() {
        if !expectedEgressIP.isEmpty {
            lookupInput = expectedEgressIP
        }
    }

    func runTests() {
        testing = true; summary = ""
        sites = Self.domains.map { Site(domain: $0.0, tag: $0.1) }
        detectChannels()
        Task {
            for i in sites.indices {
                sites[i].state = .testing
                sites[i].state = await probe(sites[i].domain)
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            let okN = sites.filter { if case .ok = $0.state { return true }; return false }.count
            let claudeAll = sites.filter { $0.tag == "Claude" }
            let claudeOK = claudeAll.allSatisfy { if case .ok = $0.state { return true }; return false }
            let claudeFail = claudeAll.filter { if case .ok = $0.state { return false }; return true }.count

            if okN == sites.count      { summary = "全部畅通! 放心打开 Claude" }
            else if claudeOK           { summary = "Claude 可用, 部分基准站不通" }
            else if claudeFail > 0     { summary = "Claude 有 \(claudeFail) 个域名不通" }
            else                       { summary = "全军覆没 — 检查网络和代理" }
            testing = false
        }
    }

    /// Quick overall status for menu bar icon
    var overallOK: Bool? {
        if testing { return nil }
        if sites.isEmpty { return nil }
        let claudeSites = sites.filter { $0.tag == "Claude" }
        if claudeSites.isEmpty { return nil }
        return claudeSites.allSatisfy { if case .ok = $0.state { return true }; return false }
    }

    private func geo(_ ip: String?) async -> IPGeo? {
        let u = ip != nil ? "https://ipapi.co/\(ip!)/json/" : "https://ipapi.co/json/"
        guard let url = URL(string: u) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("ProxyPulse/1.0", forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let g = try? JSONDecoder().decode(IPGeo.self, from: data),
           g.ip != nil { return g }
        if ip == nil,
           let url2 = URL(string: "https://api.ipify.org?format=json"),
           let (d, _) = try? await URLSession.shared.data(from: url2),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let s = j["ip"] as? String {
            return IPGeo(ip: s, city: nil, region: nil, country_name: nil, org: nil, timezone: nil)
        }
        return nil
    }

    private func probe(_ domain: String) async -> Chk {
        guard let url = URL(string: "https://\(domain)") else { return .fail("bad url") }
        let t0 = Date()
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "HEAD"
        do {
            let (_, resp) = try await probeSess.data(for: req)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            if let http = resp as? HTTPURLResponse,
               (301...302).contains(http.statusCode),
               let loc = http.value(forHTTPHeaderField: "Location"),
               loc.contains("unavailable-in-region") { return .blocked }
            return .ok(ms)
        } catch let e as URLError {
            switch e.code {
            case .timedOut: return .fail("超时")
            case .cannotConnectToHost: return .fail("拒绝")
            case .notConnectedToInternet: return .fail("无网络")
            default: return .fail("失败")
            }
        } catch { return .fail("失败") }
    }
}

// MARK: - Content View (popover)

struct ContentView: View {
    @StateObject private var vm = VM()
    @State private var appeared = false
    @State private var editingExpectedIP = false
    @State private var expectedEgressDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.top, 12).padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    channelCard
                    ipCard
                    healthCard
                    timezoneCard
                    lookupSection
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            }

            footer
        }
        .frame(width: 500, height: 720)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
            expectedEgressDraft = vm.expectedEgressIP
            editingExpectedIP = vm.expectedEgressIP.isEmpty
            vm.boot()
        }
        .environmentObject(vm)
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("Proxy Pulse").font(.system(size: 17, weight: .bold))
            Spacer()
            Text("只读诊断").font(.system(size: 12)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
    }

    // MARK: 三通道

    var channelCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("三通道代理状态", systemImage: "network")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                refreshBtn { vm.detectChannels() }
            }
            ForEach(Array(vm.channels.enumerated()), id: \.element.id) { i, ch in
                HStack(spacing: 6) {
                    Image(systemName: ch.icon)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(ch.name).font(.system(size: 13, weight: .medium))
                            Text(ch.note).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Text(ch.detail).font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let ok = ch.ok {
                        statusPill(ok)
                    }
                }
                .padding(.vertical, 3)
                if i < vm.channels.count - 1 {
                    Divider().opacity(0.5)
                }
            }
        }
        .card()
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 8)
        .animation(.easeOut(duration: 0.3).delay(0.05), value: appeared)
    }

    // MARK: IP

    var ipCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("出口 IP", systemImage: "location.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                refreshBtn { vm.fetchMyIP() }
            }
            if vm.fetchingIP { loader("正在戳…") }
            else if let ip = vm.myIP {
                ipLine(ip)
                if editingExpectedIP || vm.expectedEgressIP.isEmpty {
                    HStack(spacing: 4) {
                        TextField("校验出口IP", text: $expectedEgressDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .onSubmit { saveExpectedIP() }
                        Button("保存") { saveExpectedIP() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        if !vm.expectedEgressIP.isEmpty {
                            Button("取消") {
                                expectedEgressDraft = vm.expectedEgressIP
                                editingExpectedIP = false
                            }.controlSize(.small)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Text("目标").font(.system(size: 12, weight: .medium))
                        Text(vm.expectedEgressIP)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("修改") {
                            expectedEgressDraft = vm.expectedEgressIP
                            editingExpectedIP = true
                        }.controlSize(.mini)
                    }
                }
                egressIPCheck(currentIP: ip.ip, expectedInput: vm.expectedEgressIP)
            }
            else if vm.ipFailed {
                Text("获取失败").font(.system(size: 13)).foregroundColor(.red)
            }
        }
        .card()
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 8)
        .animation(.easeOut(duration: 0.3).delay(0.1), value: appeared)
    }

    // MARK: Health

    var healthCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("域名连通性", systemImage: "heart.text.square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                if vm.testing { ProgressView().controlSize(.small).scaleEffect(0.7) }
                refreshBtn { vm.runTests() }.disabled(vm.testing)
            }
            let cols = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
            LazyVGrid(columns: cols, spacing: 3) {
                ForEach(vm.sites) { s in
                    HStack(spacing: 4) {
                        stateIcon(s.state).frame(width: 12, height: 12)
                        Text(shortDomain(s.domain))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if case .ok(let ms) = s.state {
                            Text("\(ms)ms").font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.green)
                        } else if case .blocked = s.state {
                            Text("受限").font(.system(size: 11, weight: .medium))
                                .foregroundColor(.orange)
                        } else if case .fail(let r) = s.state {
                            Text(r).font(.system(size: 11)).foregroundColor(.red)
                        }
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(stateBG(s.state)).cornerRadius(4)
                }
            }
            if !vm.summary.isEmpty {
                Text(vm.summary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(summaryColor)
                    .frame(maxWidth: .infinity).padding(6)
                    .background(summaryColor.opacity(0.1)).cornerRadius(5)
            }
        }
        .card()
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 8)
        .animation(.easeOut(duration: 0.3).delay(0.15), value: appeared)
    }

    // MARK: Timezone

    var timezoneCard: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.system(size: 13)).foregroundColor(.secondary)
            Text("时区一致性").font(.system(size: 13, weight: .medium))
            Spacer()
            if let ipTZ = vm.myIP?.timezone {
                let sysTZ = TimeZone.current.identifier
                let match = ipTZ == sysTZ
                HStack(spacing: 4) {
                    Text(match ? "一致" : "\(sysTZ) ≠ \(ipTZ)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(match ? .green : .orange)
                    Image(systemName: match ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(match ? .green : .orange)
                        .font(.system(size: 12))
                }
            } else {
                Text(vm.fetchingIP ? "检测中…" : "待检测")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        .card()
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 8)
        .animation(.easeOut(duration: 0.3).delay(0.18), value: appeared)
    }

    // MARK: Lookup

    var lookupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                let next = !vm.showLookup
                withAnimation(.easeInOut(duration: 0.2)) { vm.showLookup = next }
                if next { vm.prefillLookupFromExpected() }
            }) {
                HStack {
                    Label("查一个 IP", systemImage: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: vm.showLookup ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }.buttonStyle(.plain)
            if vm.showLookup {
                HStack(spacing: 4) {
                    TextField("IP 地址", text: $vm.lookupInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .onSubmit { vm.lookup() }
                    Button("查") { vm.lookup() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                if vm.lookingUp { loader("查询中…") }
                else if let r = vm.lookupResult { ipLine(r) }
                else if vm.lookupFailed {
                    Text("查询失败").font(.system(size: 13)).foregroundColor(.red)
                }
            }
        }
        .card()
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 8)
        .animation(.easeOut(duration: 0.3).delay(0.2), value: appeared)
    }

    var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Button("PixelScan") { openInSafari("https://pixelscan.net/") }
                Button("IP2Location") { openInSafari("https://www.ip2location.com/") }
            }
            .font(.system(size: 12, weight: .medium))
            .buttonStyle(.plain)
            .foregroundColor(.blue)
            Text("常驻菜单栏 · 纯诊断 · 不注入")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 5)
    }

    func openInSafari(_ urlString: String) {
        guard let url = URL(string: urlString),
              let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: safariURL, configuration: config)
    }

    // MARK: Helpers

    func ipLine(_ g: IPGeo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(g.ip ?? "—")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                if let city = g.city {
                    let parts = [city, g.region, g.country_name].compactMap { $0 }
                    Text(parts.joined(separator: ", "))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
            }
            if let org = g.org {
                Text(org).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    func egressIPCheck(currentIP: String?, expectedInput: String) -> some View {
        let expected = expectedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = (currentIP ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExpected = !expected.isEmpty
        let matched = hasExpected && !actual.isEmpty && actual == expected
        if hasExpected {
            HStack(spacing: 4) {
                Image(systemName: matched ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(matched ? .green : .red)
                    .font(.system(size: 13))
                Text(matched ? "出口IP匹配" : "出口IP不匹配")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(matched ? .green : .red)
                Spacer()
            }
        }
    }

    func shortDomain(_ d: String) -> String {
        d.replacingOccurrences(of: "statsig.anthropic.com", with: "statsig…")
         .replacingOccurrences(of: "api.anthropic.com", with: "api.anthro…")
         .replacingOccurrences(of: "platform.claude.com", with: "platform.cl…")
         .replacingOccurrences(of: "code.claude.com", with: "code.claude")
    }

    @ViewBuilder
    func stateIcon(_ s: Chk) -> some View {
        switch s {
        case .idle:    Circle().fill(Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
        case .testing: ProgressView().controlSize(.small).scaleEffect(0.5)
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 12))
        case .fail:    Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.system(size: 12))
        case .blocked: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 12))
        }
    }

    func stateBG(_ s: Chk) -> Color {
        switch s {
        case .ok: return .green.opacity(0.08)
        case .fail: return .red.opacity(0.08)
        case .blocked: return .orange.opacity(0.08)
        default: return .clear
        }
    }

    func statusPill(_ ok: Bool) -> some View {
        Text(ok ? "通" : "断")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((ok ? Color.green : Color.red), in: RoundedRectangle(cornerRadius: 5))
            .shadow(color: (ok ? Color.green : Color.red).opacity(0.4), radius: 2, y: 1)
    }

    var summaryColor: Color {
        if vm.summary.contains("畅通") { return .green }
        if vm.summary.contains("覆没") { return .red }
        return .orange
    }

    func refreshBtn(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise")
                Text("刷新")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.blue)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    func loader(_ msg: String) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(msg).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    func saveExpectedIP() {
        vm.setExpectedEgressIP(expectedEgressDraft)
        expectedEgressDraft = vm.expectedEgressIP
        editingExpectedIP = vm.expectedEgressIP.isEmpty
    }
}

// MARK: - Card modifier

struct CardMod: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
extension View { func card() -> some View { modifier(CardMod()) } }

// MARK: - AppDelegate (Menu Bar)

class AppDel: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: 20)
        if let btn = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            btn.image = NSImage(systemSymbolName: "network",
                                accessibilityDescription: "Proxy Pulse")?
                .withSymbolConfiguration(config)
            btn.image?.isTemplate = true
            btn.action = #selector(togglePopover)
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 500, height: 720)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ContentView())

        // Close popover on outside click
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let p = self?.popover, p.isShown { p.performClose(nil) }
        }
    }

    @objc func togglePopover(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if let btn = statusItem.button {
                popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "关于 Proxy Pulse",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Proxy Pulse",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Reset menu so left click works normally next time
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

// MARK: - Main

let app = NSApplication.shared
let del = AppDel()
app.delegate = del
app.setActivationPolicy(.accessory)  // No dock icon
app.run()
