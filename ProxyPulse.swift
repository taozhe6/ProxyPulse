import Cocoa
import SwiftUI

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

// MARK: - Theme

enum T {
    static let bg      = Color(red: 0.98, green: 0.96, blue: 0.93)
    static let card    = Color.white
    static let accent  = Color(red: 0.90, green: 0.38, blue: 0.22)
    static let ok      = Color(red: 0.20, green: 0.72, blue: 0.40)
    static let warn    = Color(red: 0.93, green: 0.60, blue: 0.15)
    static let fail    = Color(red: 0.84, green: 0.22, blue: 0.22)
    static let txt     = Color(red: 0.15, green: 0.14, blue: 0.13)
    static let txt2    = Color(red: 0.52, green: 0.49, blue: 0.45)
    static let subtle  = Color(red: 0.92, green: 0.90, blue: 0.87)
    static let shadow  = Color.black.opacity(0.06)
    static func f(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: s, weight: w, design: .rounded)
    }
    static func mono(_ s: CGFloat) -> Font { .system(size: s, design: .monospaced) }
}

// MARK: - Models

struct IPGeo: Codable {
    let ip: String?; let city: String?; let region: String?
    let country_name: String?; let org: String?
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
            ChanStatus(name: "网页端", icon: "🌐", note: "小火箭管控", ok: nil, detail: "检测中..."),
            ChanStatus(name: "终端", icon: "⬛", note: "env var", ok: nil, detail: "检测中..."),
            ChanStatus(name: "桌面应用", icon: "🖥", note: "launchctl", ok: nil, detail: "检测中..."),
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
                ChanStatus(name: "网页端", icon: "🌐", note: "小火箭管控",
                           ok: webOK, detail: webOK ? "系统代理已开启" : "系统代理未开启"),
                ChanStatus(name: "终端", icon: "⬛", note: "env var",
                           ok: termOK, detail: termOK ? termProxy! : "未设置 → proxy_on"),
                ChanStatus(name: "桌面应用", icon: "🖥", note: "launchctl",
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

            if okN == sites.count      { summary = "全部畅通! 放心打开 Claude 🎉" }
            else if claudeOK           { summary = "Claude 可用, 部分基准站不通 🤔" }
            else if claudeFail > 0     { summary = "Claude 有 \(claudeFail) 个域名不通 🔧" }
            else                       { summary = "全军覆没 — 检查网络和代理 🔌" }
            testing = false
        }
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
            return IPGeo(ip: s, city: nil, region: nil, country_name: nil, org: nil)
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

// MARK: - Card

struct CardMod: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(T.card).cornerRadius(12)
            .shadow(color: T.shadow, radius: 8, y: 3)
    }
}
extension View { func card() -> some View { modifier(CardMod()) } }

// MARK: - Content View

struct ContentView: View {
    @StateObject private var vm = VM()
    @State private var appeared = false
    @State private var editingExpectedIP = false
    @State private var expectedEgressDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.top, 10).padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    channelCard
                    ipCard
                    healthCard
                    lookupSection
                }
                .padding(.horizontal, 20).padding(.bottom, 14)
            }

            footer
        }
        .background(
            ZStack {
                T.bg
                LinearGradient(colors: [T.accent.opacity(0.05), .clear],
                               startPoint: .topLeading, endPoint: .center)
            }
        )
        .frame(minWidth: 460, idealWidth: 520, minHeight: 700, idealHeight: 736)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            expectedEgressDraft = vm.expectedEgressIP
            editingExpectedIP = vm.expectedEgressIP.isEmpty
            vm.boot()
        }
    }

    var header: some View {
        HStack(spacing: 5) {
            Text("🧭").font(.system(size: 22))
                .rotationEffect(.degrees(appeared ? 0 : -25))
                .animation(.interpolatingSpring(stiffness: 70, damping: 7).delay(0.15), value: appeared)
            Text("Proxy Pulse").font(T.f(20, .heavy)).foregroundColor(T.txt)
            Spacer()
            Text("只读诊断 · 关掉无副作用").font(T.f(10)).foregroundColor(T.txt2)
        }
        .padding(.horizontal, 20)
    }

    // MARK: 三通道

    var channelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("三通道代理状态").font(T.f(13, .bold)).foregroundColor(T.accent)
                Spacer()
                refreshBtn { vm.detectChannels() }
            }
            ForEach(Array(vm.channels.enumerated()), id: \.element.id) { i, ch in
                HStack(spacing: 8) {
                    Text(ch.icon).font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(ch.name).font(T.f(12, .semibold)).foregroundColor(T.txt)
                            Text(ch.note).font(T.f(10)).foregroundColor(T.txt2)
                        }
                        Text(ch.detail).font(T.mono(10)).foregroundColor(T.txt2).lineLimit(1)
                    }
                    Spacer()
                    if let ok = ch.ok {
                        pill(ok ? "通" : "断", ok ? T.ok : T.fail)
                    }
                }
                .padding(.vertical, 4)
                if i < vm.channels.count - 1 { Divider().opacity(0.3) }
            }
        }
        .card()
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
        .animation(.easeOut(duration: 0.4).delay(0.05), value: appeared)
    }

    // MARK: IP

    var ipCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("🌍").font(.system(size: 14))
                Text("你的出口 IP").font(T.f(13, .bold)).foregroundColor(T.accent)
                Spacer()
                refreshBtn { vm.fetchMyIP() }
            }
            if vm.fetchingIP { loader("正在戳…") }
            else if let ip = vm.myIP {
                ipLine(ip)
                if editingExpectedIP || vm.expectedEgressIP.isEmpty {
                    HStack(spacing: 6) {
                        TextField("输入要校验的出口IP（可保存）", text: $expectedEgressDraft)
                            .textFieldStyle(.roundedBorder).font(T.mono(12))
                            .onSubmit { saveExpectedIP() }
                        Button(action: { saveExpectedIP() }) {
                            Text("保存").font(T.f(12, .semibold)).foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(T.accent).cornerRadius(6)
                        }.buttonStyle(.plain)
                        if !vm.expectedEgressIP.isEmpty {
                            Button(action: {
                                expectedEgressDraft = vm.expectedEgressIP
                                editingExpectedIP = false
                            }) {
                                Text("取消").font(T.f(12, .semibold)).foregroundColor(T.txt2)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(T.subtle).cornerRadius(6)
                            }.buttonStyle(.plain)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Text("校验目标IP").font(T.f(11, .semibold)).foregroundColor(T.txt)
                        Text(vm.expectedEgressIP).font(T.mono(11)).foregroundColor(T.txt2)
                        Spacer()
                        Button(action: {
                            expectedEgressDraft = vm.expectedEgressIP
                            editingExpectedIP = true
                        }) {
                            Text("修改").font(T.f(12, .semibold)).foregroundColor(T.accent)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(T.accent.opacity(0.10)).cornerRadius(6)
                        }.buttonStyle(.plain)
                    }
                }
                Text("已保存的校验IP会自动预填到“查一个 IP”")
                    .font(T.f(10)).foregroundColor(T.txt2)
                egressIPCheck(currentIP: ip.ip, expectedInput: vm.expectedEgressIP)
            }
            else if vm.ipFailed {
                Text("获取失败").font(T.f(12)).foregroundColor(T.fail)
            }
        }
        .card()
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
        .animation(.easeOut(duration: 0.4).delay(0.1), value: appeared)
    }

    // MARK: Health

    var healthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("🏥").font(.system(size: 14))
                Text("域名连通性").font(T.f(13, .bold)).foregroundColor(T.accent)
                Spacer()
                if vm.testing { ProgressView().controlSize(.small).scaleEffect(0.7) }
                refreshBtn { vm.runTests() }.disabled(vm.testing)
            }
            let cols = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(vm.sites) { s in
                    HStack(spacing: 4) {
                        stateIcon(s.state).frame(width: 12, height: 12)
                        Text(shortDomain(s.domain))
                            .font(T.mono(10)).foregroundColor(T.txt).lineLimit(1)
                        Spacer()
                        if case .ok(let ms) = s.state {
                            Text("\(ms)ms").font(T.mono(9)).foregroundColor(T.ok.opacity(0.7))
                        } else if case .blocked = s.state {
                            Text("受限").font(T.f(9, .medium)).foregroundColor(T.warn)
                        } else if case .fail(let r) = s.state {
                            Text(r).font(T.f(9)).foregroundColor(T.fail)
                        }
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(stateBG(s.state)).cornerRadius(5)
                }
            }
            if !vm.summary.isEmpty {
                Text(vm.summary)
                    .font(T.f(12, .semibold)).foregroundColor(summaryColor)
                    .frame(maxWidth: .infinity).padding(8)
                    .background(summaryColor.opacity(0.08)).cornerRadius(6)
            }
        }
        .card()
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
        .animation(.easeOut(duration: 0.4).delay(0.15), value: appeared)
    }

    // MARK: Lookup (折叠)

    var lookupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                let next = !vm.showLookup
                withAnimation(.easeInOut(duration: 0.2)) { vm.showLookup = next }
                if next { vm.prefillLookupFromExpected() }
            }) {
                HStack {
                    Text("🔍").font(.system(size: 14))
                    Text("查一个 IP").font(T.f(13, .bold)).foregroundColor(T.accent)
                    Spacer()
                    Image(systemName: vm.showLookup ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10)).foregroundColor(T.txt2)
                }
            }.buttonStyle(.plain)
            if vm.showLookup {
                HStack(spacing: 6) {
                    TextField("输入要查询的IP", text: $vm.lookupInput)
                        .textFieldStyle(.roundedBorder).font(T.mono(12))
                        .onSubmit { vm.lookup() }
                    Button(action: { vm.lookup() }) {
                        Text("查").font(T.f(12, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(T.accent).cornerRadius(6)
                    }.buttonStyle(.plain)
                }
                if vm.lookingUp { loader("查询中…") }
                else if let r = vm.lookupResult { ipLine(r) }
                else if vm.lookupFailed {
                    Text("查询失败").font(T.f(11)).foregroundColor(T.fail)
                }
            }
        }
        .card()
        .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 10)
        .animation(.easeOut(duration: 0.4).delay(0.2), value: appeared)
    }

    var footer: some View {
        Text("纯诊断工具 · 不注入 · 不驻留 · 杀掉零影响")
            .font(T.f(10)).foregroundColor(T.txt2)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(T.bg.opacity(0.95))
    }

    // MARK: Helpers

    func ipLine(_ g: IPGeo) -> some View {
        HStack(spacing: 8) {
            Text(g.ip ?? "—")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(T.txt)
            if let city = g.city {
                let parts = [city, g.region, g.country_name].compactMap { $0 }
                Text("📍 " + parts.joined(separator: ", "))
                    .font(T.f(11)).foregroundColor(T.txt2).lineLimit(1)
            }
            Spacer()
            if let org = g.org {
                Text(org).font(T.f(10)).foregroundColor(T.txt2.opacity(0.7)).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    func egressIPCheck(currentIP: String?, expectedInput: String) -> some View {
        let expected = expectedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = (currentIP ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExpected = !expected.isEmpty
        let matched = hasExpected && !actual.isEmpty && actual == expected
        HStack(spacing: 6) {
            Text("目标出口IP")
                .font(T.f(11, .semibold))
                .foregroundColor(T.txt)
            Text(hasExpected ? expected : "未设置")
                .font(T.mono(11))
                .foregroundColor(T.txt2)
            Spacer()
            if !hasExpected {
                pill("待设置", T.warn)
            } else if actual.isEmpty {
                pill("未知", T.warn)
            } else {
                pill(matched ? "匹配" : "不匹配", matched ? T.ok : T.fail)
            }
        }
    }

    func shortDomain(_ d: String) -> String {
        d.replacingOccurrences(of: ".anthropic.com", with: "…a.c")
    }

    @ViewBuilder
    func stateIcon(_ s: Chk) -> some View {
        switch s {
        case .idle:    Circle().fill(T.subtle).frame(width: 8, height: 8)
        case .testing: ProgressView().controlSize(.small).scaleEffect(0.5)
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundColor(T.ok).font(.system(size: 11))
        case .fail:    Image(systemName: "xmark.circle.fill").foregroundColor(T.fail).font(.system(size: 11))
        case .blocked: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(T.warn).font(.system(size: 11))
        }
    }

    func stateBG(_ s: Chk) -> Color {
        switch s {
        case .ok: return T.ok.opacity(0.06)
        case .fail: return T.fail.opacity(0.06)
        case .blocked: return T.warn.opacity(0.06)
        default: return .clear
        }
    }

    func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(T.f(11, .bold)).foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(minWidth: 56)
            .background(RoundedRectangle(cornerRadius: 6).fill(color))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
            )
            .shadow(color: color.opacity(0.35), radius: 2, y: 1)
    }

    var summaryColor: Color {
        vm.summary.contains("🎉") ? T.ok :
        vm.summary.contains("🔌") ? T.fail : T.warn
    }

    func refreshBtn(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                Text("刷新")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(T.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(T.accent.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(T.accent.opacity(0.55), lineWidth: 1)
            )
        }.buttonStyle(.plain)
    }

    func loader(_ msg: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(msg).font(T.f(11)).foregroundColor(T.txt2)
        }
    }

    func saveExpectedIP() {
        vm.setExpectedEgressIP(expectedEgressDraft)
        expectedEgressDraft = vm.expectedEgressIP
        editingExpectedIP = vm.expectedEgressIP.isEmpty
    }
}

// MARK: - AppDelegate + close confirmation

class AppDel: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var w: NSWindow!

    // Default launch size is calculated from current visible blocks to avoid clipped first render.
    private func calculatedDefaultContentSize() -> NSSize {
        let header: CGFloat = 40
        let channelCard: CGFloat = 124
        let ipCard: CGFloat = 176
        let healthCard: CGFloat = 228
        let lookupCardCollapsed: CGFloat = 64
        let interCardSpacing: CGFloat = 14 * 3
        let verticalPadding: CGFloat = 44
        let footer: CGFloat = 24

        let height = header
            + channelCard
            + ipCard
            + healthCard
            + lookupCardCollapsed
            + interCardSpacing
            + verticalPadding
            + footer

        return NSSize(width: 520, height: ceil(height))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let defaultSize = calculatedDefaultContentSize()
        w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultSize.width, height: defaultSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.center()
        w.title = "Proxy Pulse"
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 1)
        w.contentView = NSHostingView(rootView: ContentView())
        w.makeKeyAndOrderFront(nil)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 460, height: 700)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let a = NSAlert()
        a.messageText = "关闭 Proxy Pulse?"
        a.informativeText = "放心关: 这只是诊断镜子,不注入任何东西。\n关闭后代理配置不受影响。\n(代理由 LaunchAgent + 小火箭管控)"
        a.alertStyle = .informational
        a.addButton(withTitle: "关闭")
        a.addButton(withTitle: "留着")
        return a.runModal() == .alertFirstButtonReturn
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let del = AppDel()
app.delegate = del
let menu = NSMenu(); let ai = NSMenuItem(); menu.addItem(ai)
let sub = NSMenu()
sub.addItem(withTitle: "关于 Proxy Pulse",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
sub.addItem(.separator())
sub.addItem(withTitle: "退出 Proxy Pulse",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
ai.submenu = sub; app.mainMenu = menu
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
