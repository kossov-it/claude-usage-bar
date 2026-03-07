import AppKit
import Security
import SwiftUI

// MARK: - Data Types

struct ExtraUsageData {
    let monthlyLimit: Int    // cents
    let usedCredits: Double  // cents
    let utilization: Double
}

struct UsageData {
    let sessionUtilization: Double
    let sessionResetsAt: Date
    let weeklyUtilization: Double
    let weeklyResetsAt: Date
    let extraUsage: ExtraUsageData?
    let planMultiplier: Int  // 0 = Pro/standard, 5 = Max 5×, 20 = Max 20×
}

enum UsageLevel {
    case normal, elevated, critical

    init(_ utilization: Double) {
        if utilization >= 80 { self = .critical }
        else if utilization >= 50 { self = .elevated }
        else { self = .normal }
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .elevated: return .yellow
        case .critical: return .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .elevated: return .systemYellow
        case .critical: return .systemRed
        }
    }
}

enum UsageError: LocalizedError {
    case noToken
    case tokenExpired
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No credentials — sign in with Claude Code"
        case .tokenExpired:
            return "Session expired — open Claude Code"
        case .httpError(let code):
            if code == 429 { return "Rate limited — will retry" }
            return code == 0 ? "No response from API" : "API error (HTTP \(code))"
        }
    }
}

// MARK: - Service

actor UsageService {
    private let usageEndpoint: URL = {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            fatalError("Invalid usage endpoint URL")
        }
        return url
    }()
    private let keychainService = "Claude Code-credentials"
    private let keychainAccount = NSUserName()

    // Token cache — avoids keychain reads on every poll
    private var cachedToken: String?
    private var cachedTokenExpiry: Date?

    private func readAccessToken() -> (token: String, expiresAt: Date?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            return nil
        }
        let expiresAt: Date?
        if let expiresAtMs = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000.0)
        } else {
            expiresAt = nil
        }
        return (token: accessToken, expiresAt: expiresAt)
    }

    private func getValidToken() -> (token: String, expired: Bool)? {
        if let token = cachedToken {
            if let expiry = cachedTokenExpiry, expiry < Date() {
                cachedToken = nil
                cachedTokenExpiry = nil
            } else {
                return (token: token, expired: false)
            }
        }
        guard let creds = readAccessToken() else { return nil }
        cachedToken = creds.token
        cachedTokenExpiry = creds.expiresAt
        let expired = creds.expiresAt.map { $0 < Date() } ?? false
        return (token: creds.token, expired: expired)
    }

    private func invalidateCache() {
        cachedToken = nil
        cachedTokenExpiry = nil
    }

    private var lastRefreshAttempt: Date = .distantPast

    @discardableResult
    private func openClaudeInTerminal() async -> Bool {
        guard Date().timeIntervalSince(lastRefreshAttempt) > 300 else { return false }
        let success = await MainActor.run {
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: """
                tell application "Terminal"
                    activate
                    do script "claude"
                end tell
                """)
            script?.executeAndReturnError(&errorInfo)
            return errorInfo == nil
        }
        if success {
            lastRefreshAttempt = Date()
        }
        return success
    }

    private let accountEndpoint: URL = {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/account") else {
            fatalError("Invalid account endpoint URL")
        }
        return url
    }()
    private var cachedPlanMultiplier: Int?
    private var lastAccountAttempt: Date = .distantPast

    /// Fetches rate_limit_tier from /api/oauth/account once per session.
    /// On failure, waits 5 minutes before retrying to avoid burning rate limit.
    private func fetchPlanMultiplier(token: String) async -> Int {
        if let cached = cachedPlanMultiplier { return cached }
        guard Date().timeIntervalSince(lastAccountAttempt) > 300 else { return 0 }
        lastAccountAttempt = Date()
        var req = URLRequest(url: accountEndpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let memberships = json["memberships"] as? [[String: Any]],
              let org = memberships.first?["organization"] as? [String: Any],
              let tier = org["rate_limit_tier"] as? String else {
            return 0
        }
        let multiplier: Int
        if tier.contains("20x") { multiplier = 20 }
        else if tier.contains("5x") { multiplier = 5 }
        else { multiplier = 0 }
        cachedPlanMultiplier = multiplier
        return multiplier
    }

    func fetchUsage() async throws -> UsageData {
        guard let creds = getValidToken() else {
            await openClaudeInTerminal()
            throw UsageError.noToken
        }

        if creds.expired {
            invalidateCache()
            await openClaudeInTerminal()
            throw UsageError.tokenExpired
        }

        let (data, response) = try await makeUsageRequest(token: creds.token)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.httpError(0)
        }

        if httpResponse.statusCode == 401 {
            invalidateCache()
            await openClaudeInTerminal()
            throw UsageError.tokenExpired
        }

        guard httpResponse.statusCode == 200 else {
            throw UsageError.httpError(httpResponse.statusCode)
        }

        // Fetch plan tier after successful usage request (cached after first success)
        let multiplier = await fetchPlanMultiplier(token: creds.token)
        return try decodeUsage(data, planMultiplier: multiplier)
    }

    private func makeUsageRequest(token: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: usageEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        return try await URLSession.shared.data(for: request)
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func decodeUsage(_ data: Data, planMultiplier: Int) throws -> UsageData {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = UsageService.isoPlain.date(from: string) { return date }
            if let date = UsageService.isoFractional.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid date: \(string)"
            )
        }
        let raw = try decoder.decode(UsageResponse.self, from: data)

        var extra: ExtraUsageData?
        if let e = raw.extraUsage, e.isEnabled,
           let limit = e.monthlyLimit, let used = e.usedCredits {
            let util = e.utilization?.value
                ?? (limit.value > 0 ? used.value / limit.value * 100.0 : 0)
            extra = ExtraUsageData(
                monthlyLimit: Int(limit.value),
                usedCredits: used.value,
                utilization: util
            )
        }

        return UsageData(
            sessionUtilization: raw.fiveHour?.utilization ?? 0,
            sessionResetsAt: raw.fiveHour?.resetsAt ?? .distantFuture,
            weeklyUtilization: raw.sevenDay?.utilization ?? 0,
            weeklyResetsAt: raw.sevenDay?.resetsAt ?? .distantFuture,
            extraUsage: extra,
            planMultiplier: planMultiplier
        )
    }
}

private struct UsageResponse: Decodable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let extraUsage: ExtraUsageBucket?
}

private struct UsageBucket: Decodable {
    let utilization: Double?
    let resetsAt: Date?
}

private struct ExtraUsageBucket: Decodable {
    let isEnabled: Bool
    let monthlyLimit: FlexNum?
    let usedCredits: FlexNum?
    let utilization: FlexNum?
}

/// Decodes JSON numbers that may arrive as Int or Double.
private struct FlexNum: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else { value = Double(try c.decode(Int.self)) }
    }
}

// MARK: - Formatting

/// Formats cents as dollars, showing cents only when non-zero.
/// 2000 → "$20"   1712 → "$17.12"   50 → "$0.50"
private func formatDollars(_ cents: Double) -> String {
    let dollars = cents / 100.0
    if abs(dollars.truncatingRemainder(dividingBy: 1)) < 0.005 {
        return String(format: "$%.0f", dollars)
    }
    return String(format: "$%.2f", dollars)
}

private func countdownString(to date: Date) -> String {
    let remaining = date.timeIntervalSinceNow
    guard remaining > 0 else { return "now" }
    guard remaining < 86400 * 365 else { return "—" }
    let total = Int(remaining)
    let days = total / 86400
    let hours = (total % 86400) / 3600
    let minutes = (total % 3600) / 60
    if days > 0 {
        return String(format: "%dd %dh %02dm", days, hours, minutes)
    }
    if hours > 0 {
        return String(format: "%dh %02dm", hours, minutes)
    }
    return "\(minutes)m"
}

// MARK: - View

final class UsageViewModel: ObservableObject {
    @Published var sessionUtilization: Double = 0
    @Published var sessionResetsAt: Date = .distantFuture
    @Published var weeklyUtilization: Double = 0
    @Published var weeklyResetsAt: Date = .distantFuture
    @Published var extraUsage: ExtraUsageData?
    @Published var lastUpdated: Date?
    @Published var error: String?
    @Published var planMultiplier: Int = 0

    func apply(_ data: UsageData) {
        sessionUtilization = data.sessionUtilization
        sessionResetsAt = data.sessionResetsAt
        weeklyUtilization = data.weeklyUtilization
        weeklyResetsAt = data.weeklyResetsAt
        extraUsage = data.extraUsage
        planMultiplier = data.planMultiplier
        lastUpdated = Date()
        error = nil
    }
}

struct UsageView: View {
    @ObservedObject var viewModel: UsageViewModel
    var onRefresh: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                UsageColumn(
                    label: "Session",
                    utilization: viewModel.sessionUtilization,
                    topDetail: "Resets in",
                    bottomDetail: countdownString(to: viewModel.sessionResetsAt)
                )
                UsageColumn(
                    label: "Week",
                    utilization: viewModel.weeklyUtilization,
                    topDetail: "Resets in",
                    bottomDetail: countdownString(to: viewModel.weeklyResetsAt)
                )
            }

            if let extra = viewModel.extraUsage {
                Divider()
                    .padding(.vertical, 8)
                HStack(spacing: 6) {
                    Text("Extra")
                        .font(.body.weight(.semibold))
                        .frame(width: 42, alignment: .leading)
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 3.5)
                        Circle()
                            .trim(from: 0, to: max(0, min(extra.utilization / 100.0, 1.0)))
                            .stroke(UsageLevel(extra.utilization).color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(String(format: "%.0f%%", extra.utilization))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    }
                    .frame(width: 32, height: 32)
                    Text("\(formatDollars(extra.usedCredits)) / \(formatDollars(Double(extra.monthlyLimit)))")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            if let error = viewModel.error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
                .padding(.top, 8)
            }

            Divider()
                .padding(.vertical, 8)

            HStack(spacing: 6) {
                if let lastUpdated = viewModel.lastUpdated {
                    Text(relativeTime(lastUpdated))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if viewModel.planMultiplier > 1 {
                    HStack(spacing: 2) {
                        Text("Max")
                            .fontWeight(.bold)
                        Text("\(viewModel.planMultiplier)×")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(8)
                    .fixedSize()
                }
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Button(action: onQuit) {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 14, trailing: 12))
        .fixedSize()
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, -date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h ago" : "\(minutes)m ago"
    }
}

private struct UsageColumn: View {
    let label: String
    let utilization: Double
    let topDetail: String
    let bottomDetail: String?

    private let circleSize: CGFloat = 42
    private let strokeWidth: CGFloat = 5.5

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.body.weight(.semibold))
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: strokeWidth)
                Circle()
                    .trim(from: 0, to: max(0, min(utilization / 100.0, 1.0)))
                    .stroke(UsageLevel(utilization).color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(String(format: "%.0f%%", utilization))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .frame(width: circleSize, height: circleSize)
            VStack(spacing: 1) {
                Text(topDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let bottom = bottomDetail {
                    Text(bottom)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var pollTimer: Timer?
    private var eventMonitor: Any?
    private var isPolling = false

    private let service = UsageService()
    private let viewModel = UsageViewModel()
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 52)

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            updateButton(button, utilization: 0, color: .secondaryLabelColor, text: "—")
        }

        let hostingController = NSHostingController(
            rootView: UsageView(viewModel: viewModel, onRefresh: { [weak self] in
                self?.poll()
            }, onQuit: {
                NSApplication.shared.terminate(nil)
            })
        )
        hostingController.sizingOptions = .preferredContentSize

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hostingController

        poll()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.current.add(timer, forMode: .common)
        pollTimer = timer
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Periodic usage polling"
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.poll()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func poll() {
        guard !isPolling else { return }
        isPolling = true
        Task { @MainActor in
            defer { isPolling = false }
            do {
                let data = try await service.fetchUsage()
                applyData(data)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func applyData(_ data: UsageData) {
        viewModel.apply(data)
        if let button = statusItem.button {
            if data.weeklyUtilization >= 100 {
                updateButton(button, utilization: 100, color: .systemRed, text: "X")
            } else {
                let color = UsageLevel(data.sessionUtilization).nsColor
                let text = String(format: "%.0f%%", data.sessionUtilization)
                updateButton(button, utilization: data.sessionUtilization, color: color, text: text)
            }
        }
    }

    private func showError(_ message: String) {
        viewModel.error = message
        // Only reset menu bar icon if we never had good data — keeps last known state visible
        if viewModel.lastUpdated == nil {
            if let button = statusItem.button {
                updateButton(button, utilization: 0, color: .secondaryLabelColor, text: "—")
            }
        }
    }

    private func makeProgressRingImage(utilization: Double, color: NSColor, size: CGFloat = 14) -> NSImage {
        let lineWidth: CGFloat = 2.0
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = (size - lineWidth) / 2

            let bgPath = NSBezierPath()
            bgPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            bgPath.lineWidth = lineWidth
            NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke()
            bgPath.stroke()

            let fraction = min(max(utilization / 100.0, 0), 1.0)
            if fraction > 0 {
                let startAngle: CGFloat = 90
                let endAngle = 90 - fraction * 360
                let arcPath = NSBezierPath()
                arcPath.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
                arcPath.lineWidth = lineWidth
                arcPath.lineCapStyle = .round
                color.setStroke()
                arcPath.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private func updateButton(_ button: NSStatusBarButton, utilization: Double, color: NSColor, text: String) {
        button.image = makeProgressRingImage(utilization: utilization, color: color)
        button.imagePosition = .imageLeading
        button.title = " \(text)"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
