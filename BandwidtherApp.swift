import SwiftUI
import AppKit
import Combine
import Darwin
import Foundation

// MARK: - Data Models

struct BandwidthRate {
    let bytesInPerSec: Double
    let bytesOutPerSec: Double

    var totalPerSec: Double { bytesInPerSec + bytesOutPerSec }

    static let zero = BandwidthRate(bytesInPerSec: 0, bytesOutPerSec: 0)
}

struct ProcessBandwidth: Identifiable {
    let id: String  // process name
    let name: String
    let bytesInPerSec: Double
    let bytesOutPerSec: Double
    let totalBytesIn: UInt64
    let totalBytesOut: UInt64
    let connections: Int

    var totalPerSec: Double { bytesInPerSec + bytesOutPerSec }
    var totalBytes: UInt64 { totalBytesIn + totalBytesOut }
}

enum ProcessSortKey: String, CaseIterable {
    case totalRate = "Rate"
    case download = "Down"
    case upload = "Up"
    case totalBytes = "Total"
    case name = "Name"
}

struct ConnectionSummary {
    var internetCount: Int = 0
    var lanCount: Int = 0
    var internetProcesses: [String: Int] = [:]
    var lanProcesses: [String: Int] = [:]
    var internetDestinations: [String] = []
    var lanDestinations: [String] = []
}

struct NetworkEndpoint {
    let host: String
    let port: String

    var displayString: String {
        if host.contains(":") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }
}

// MARK: - Reverse DNS Cache

class DNSCache: ObservableObject {
    @Published var resolved: [String: String] = [:]  // ip -> hostname
    private var pending: Set<String> = []
    private let queue = DispatchQueue(label: "dns-resolver", attributes: .concurrent)

    func resolve(_ ip: String) {
        // Already resolved or in-flight
        if resolved[ip] != nil || pending.contains(ip) { return }
        pending.insert(ip)

        queue.async { [weak self] in
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result: Int32

            if ip.contains(":") {
                var sa = sockaddr_in6()
                sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                sa.sin6_family = sa_family_t(AF_INET6)
                result = inet_pton(AF_INET6, ip, &sa.sin6_addr) == 1
                    ? withUnsafePointer(to: &sa) { saPtr in
                        saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            getnameinfo(sockPtr, socklen_t(MemoryLayout<sockaddr_in6>.size),
                                        &hostname, socklen_t(hostname.count),
                                        nil, 0, NI_NAMEREQD)
                        }
                    }
                    : EAI_NONAME
            } else {
                var sa = sockaddr_in()
                sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sa.sin_family = sa_family_t(AF_INET)
                result = inet_pton(AF_INET, ip, &sa.sin_addr) == 1
                    ? withUnsafePointer(to: &sa) { saPtr in
                        saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            getnameinfo(sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                                        &hostname, socklen_t(hostname.count),
                                        nil, 0, NI_NAMEREQD)
                        }
                    }
                    : EAI_NONAME
            }

            let name: String?
            if result == 0 {
                let resolved = String(cString: hostname)
                // getnameinfo returns the IP back if it can't resolve — skip those
                name = (resolved != ip) ? resolved : nil
            } else {
                name = nil
            }

            DispatchQueue.main.async {
                self?.pending.remove(ip)
                if let name = name {
                    self?.resolved[ip] = name
                } else {
                    // Store empty string so we don't retry
                    self?.resolved[ip] = ""
                }
            }
        }
    }

    func hostname(for ip: String) -> String? {
        if let name = resolved[ip], !name.isEmpty { return name }
        return nil
    }
}

// MARK: - Nettop Parser

struct NettopProcessData {
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var pids: Set<String> = []
}

struct NettopResult {
    // Cumulative totals (from first sample)
    var totals: [String: NettopProcessData] = [:]
    // Delta rates per second (from second sample)
    var deltas: [String: NettopProcessData] = [:]
    var errorMessage: String?
}

private func parseNettopCSVBlock(_ lines: [String]) -> [String: NettopProcessData] {
    var result: [String: NettopProcessData] = [:]
    for line in lines {
        let cols = line.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        // Expect: name.pid, bytes_in, bytes_out, (trailing comma)
        guard cols.count >= 3 else { continue }
        let nameField = cols[0]
        if nameField.isEmpty || nameField.hasPrefix("time") { continue }

        guard let bytesIn = UInt64(cols[1]), let bytesOut = UInt64(cols[2]) else { continue }

        // Extract process name and PID from "ProcessName.12345"
        var procName = nameField
        var pid = ""
        if let dotRange = nameField.range(of: ".", options: .backwards) {
            let suffix = String(nameField[dotRange.upperBound...])
            if Int(suffix) != nil {
                procName = String(nameField[nameField.startIndex..<dotRange.lowerBound])
                pid = suffix
            }
        }
        // Handle names with spaces like "LM Studio.1234"
        if procName.isEmpty { continue }

        var existing = result[procName] ?? NettopProcessData()
        existing.bytesIn += bytesIn
        existing.bytesOut += bytesOut
        if !pid.isEmpty { existing.pids.insert(pid) }
        result[procName] = existing
    }
    return result
}

func runNettop() -> NettopResult {
    let pipe = Pipe()
    let errorPipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    // -d: delta mode, -P: per-process summary, -L 2: baseline sample then one delta,
    // -s 1: 1 second interval, -x: raw numbers, -n: no DNS, -J: only these columns
    proc.arguments = ["-d", "-P", "-L", "2", "-s", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
    proc.standardOutput = pipe
    proc.standardError = errorPipe

    do { try proc.run() } catch {
        return NettopResult(errorMessage: "Failed to start nettop: \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    let stderr = String(data: errorData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard proc.terminationStatus == 0 else {
        let detail = stderr.isEmpty ? "nettop exited with status \(proc.terminationStatus)" : stderr
        return NettopResult(errorMessage: detail)
    }

    guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
        let detail = stderr.isEmpty ? "nettop returned no output" : stderr
        return NettopResult(errorMessage: detail)
    }

    // Split into two blocks at the second header line
    let allLines = output.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

    var blocks: [[String]] = []
    var current: [String] = []
    for line in allLines {
        if line.hasPrefix(",bytes_in") {
            if !current.isEmpty { blocks.append(current) }
            current = []
        } else {
            current.append(line)
        }
    }
    if !current.isEmpty { blocks.append(current) }

    guard blocks.count >= 2 else {
        return NettopResult(errorMessage: "nettop did not return a baseline and delta sample")
    }

    var result = NettopResult()
    if blocks.count >= 1 { result.totals = parseNettopCSVBlock(blocks[0]) }
    if blocks.count >= 2 { result.deltas = parseNettopCSVBlock(blocks[1]) }
    return result
}

// MARK: - Lightweight Network Rate Monitor (getifaddrs)

/// Reads aggregate network byte counters via getifaddrs() and computes rates
/// from deltas between consecutive calls. No subprocess needed — just a fast
/// syscall. Used for menu bar updates when the popover is closed.
class LightweightNetMonitor {
    private var lastReadTime: CFAbsoluteTime = 0
    private var lastCounters: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var hasBaseline = false

    /// Read current rates by computing deltas from last call.
    /// First call establishes baseline and returns .zero.
    func readRate() -> BandwidthRate {
        let counters = readInterfaceCounters()
        let now = CFAbsoluteTimeGetCurrent()

        guard hasBaseline else {
            lastCounters = counters
            lastReadTime = now
            hasBaseline = true
            return .zero
        }

        let elapsed = now - lastReadTime
        guard elapsed > 0.01 else { return .zero }

        var totalDeltaIn: UInt64 = 0
        var totalDeltaOut: UInt64 = 0

        for (name, current) in counters {
            guard let last = lastCounters[name] else { continue }
            // Handle per-interface uint32 counter wrap
            if current.bytesIn >= last.bytesIn {
                totalDeltaIn += current.bytesIn - last.bytesIn
            } else {
                totalDeltaIn += current.bytesIn + (UInt64(UInt32.max) + 1) - last.bytesIn
            }
            if current.bytesOut >= last.bytesOut {
                totalDeltaOut += current.bytesOut - last.bytesOut
            } else {
                totalDeltaOut += current.bytesOut + (UInt64(UInt32.max) + 1) - last.bytesOut
            }
        }

        lastCounters = counters
        lastReadTime = now

        // After long gaps (e.g. screen sleep), report zero rather than a spike
        if elapsed > 60.0 { return .zero }

        return BandwidthRate(
            bytesInPerSec: Double(totalDeltaIn) / elapsed,
            bytesOutPerSec: Double(totalDeltaOut) / elapsed
        )
    }

    /// Reset state so the next readRate() establishes a fresh baseline.
    func reset() {
        hasBaseline = false
        lastCounters = [:]
    }

    private func readInterfaceCounters() -> [String: (bytesIn: UInt64, bytesOut: UInt64)] {
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let firstAddr = ifaddrsPtr else { return [:] }
        defer { freeifaddrs(ifaddrsPtr) }

        var result: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let addr = current {
            defer { current = addr.pointee.ifa_next }

            let flags = Int32(addr.pointee.ifa_flags)
            guard (flags & IFF_LOOPBACK) == 0 else { continue }
            guard (flags & IFF_UP) != 0 else { continue }
            guard let sa = addr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let data = addr.pointee.ifa_data else { continue }

            let ifData = data.assumingMemoryBound(to: if_data.self).pointee
            let name = String(cString: addr.pointee.ifa_name)

            result[name] = (bytesIn: UInt64(ifData.ifi_ibytes), bytesOut: UInt64(ifData.ifi_obytes))
        }

        return result
    }
}

// MARK: - Network Monitor

class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published var currentRate = BandwidthRate.zero
    @Published var totalBytesIn: UInt64 = 0
    @Published var totalBytesOut: UInt64 = 0
    @Published var nettopStatus: String?
    @Published var connectionSummary = ConnectionSummary()
    @Published var dnsCache = DNSCache()
    @Published var rateHistory: [BandwidthRate] = []
    @Published var processBandwidths: [ProcessBandwidth] = []
    @Published var processSortKey: ProcessSortKey = .totalRate
    @Published var processSortAscending: Bool = false

    private var connTimer: Timer?
    private var nettopTimer: Timer?
    private var lightTimer: Timer?
    private var dnsCacheSubscription: AnyCancellable?
    private let lightMonitor = LightweightNetMonitor()
    private let maxHistory = 60
    private(set) var isDetailVisible = false
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var isScreenAsleep = false

    private static let nettopPollInterval: TimeInterval = 2.0
    private static let lightweightPollInterval: TimeInterval = 5.0

    init() {
        // Forward dnsCache changes so SwiftUI views observing NetworkMonitor
        // re-render when DNS resolutions complete.
        dnsCacheSubscription = dnsCache.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // Establish baseline for lightweight monitor; menu bar updates
        // will start arriving after the first lightweight timer fire.
        _ = lightMonitor.readRate()
        scheduleLightweightTimer()

        // Pause polling when the display sleeps to save energy
        screenSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenSleep()
        }
        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenWake()
        }
    }

    deinit {
        connTimer?.invalidate()
        nettopTimer?.invalidate()
        lightTimer?.invalidate()
        if let obs = screenSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = screenWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
    }

    private func scheduleNettopTimer() {
        nettopTimer?.invalidate()
        nettopTimer = Timer.scheduledTimer(withTimeInterval: Self.nettopPollInterval, repeats: true) { [weak self] _ in
            self?.refreshNettop()
        }
    }

    private func scheduleLightweightTimer() {
        lightTimer?.invalidate()
        lightTimer = Timer.scheduledTimer(withTimeInterval: Self.lightweightPollInterval, repeats: true) { [weak self] _ in
            self?.refreshLightweight()
        }
    }

    private func refreshLightweight() {
        let rate = lightMonitor.readRate()
        currentRate = rate
        rateHistory.append(rate)
        if rateHistory.count > maxHistory {
            rateHistory.removeFirst()
        }
    }

    private func handleScreenSleep() {
        isScreenAsleep = true
        nettopTimer?.invalidate()
        nettopTimer = nil
        lightTimer?.invalidate()
        lightTimer = nil
        connTimer?.invalidate()
        connTimer = nil
        lightMonitor.reset()
    }

    private func handleScreenWake() {
        isScreenAsleep = false
        if isDetailVisible {
            refreshNettop()
            scheduleNettopTimer()
            refreshConnections()
            connTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.refreshConnections()
            }
        } else {
            _ = lightMonitor.readRate()
            scheduleLightweightTimer()
        }
    }

    /// Call when the popover is shown to switch to nettop + lsof polling
    func beginDetailPolling() {
        guard !isDetailVisible else { return }
        isDetailVisible = true
        lightTimer?.invalidate()
        lightTimer = nil
        guard !isScreenAsleep else { return }
        refreshNettop()
        scheduleNettopTimer()
        refreshConnections()
        connTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshConnections()
        }
    }

    /// Call when the popover is closed to switch to lightweight polling
    func endDetailPolling() {
        guard isDetailVisible else { return }
        isDetailVisible = false
        connTimer?.invalidate()
        connTimer = nil
        nettopTimer?.invalidate()
        nettopTimer = nil
        guard !isScreenAsleep else { return }
        lightMonitor.reset()
        _ = lightMonitor.readRate()
        scheduleLightweightTimer()
    }

    func refreshNettop() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = runNettop()
            DispatchQueue.main.async {
                self?.processNettopResult(result)
            }
        }
    }

    private func processNettopResult(_ result: NettopResult) {
        if let errorMessage = result.errorMessage {
            nettopStatus = errorMessage
            return
        }

        var procs: [ProcessBandwidth] = []
        var sumRateIn: Double = 0
        var sumRateOut: Double = 0
        var sumTotalIn: UInt64 = 0
        var sumTotalOut: UInt64 = 0

        let allNames = Set(result.totals.keys).union(result.deltas.keys)

        for name in allNames {
            let total = result.totals[name]
            let delta = result.deltas[name]

            let rateIn = Double(delta?.bytesIn ?? 0)
            let rateOut = Double(delta?.bytesOut ?? 0)
            let totalIn = total?.bytesIn ?? 0
            let totalOut = total?.bytesOut ?? 0
            let pidCount = max(total?.pids.count ?? 0, delta?.pids.count ?? 0)

            sumRateIn += rateIn
            sumRateOut += rateOut
            sumTotalIn += totalIn
            sumTotalOut += totalOut

            if totalIn > 0 || totalOut > 0 {
                procs.append(ProcessBandwidth(
                    id: name,
                    name: name,
                    bytesInPerSec: rateIn,
                    bytesOutPerSec: rateOut,
                    totalBytesIn: totalIn,
                    totalBytesOut: totalOut,
                    connections: pidCount
                ))
            }
        }

        let rate = BandwidthRate(bytesInPerSec: sumRateIn, bytesOutPerSec: sumRateOut)
        currentRate = rate
        totalBytesIn = sumTotalIn
        totalBytesOut = sumTotalOut
        nettopStatus = nil
        rateHistory.append(rate)
        if rateHistory.count > maxHistory {
            rateHistory.removeFirst()
        }

        processBandwidths = sortProcesses(procs)
    }

    func sortProcesses(_ procs: [ProcessBandwidth]) -> [ProcessBandwidth] {
        let sorted: [ProcessBandwidth]
        switch processSortKey {
        case .totalRate:
            sorted = procs.sorted { $0.totalPerSec > $1.totalPerSec }
        case .download:
            sorted = procs.sorted { $0.bytesInPerSec > $1.bytesInPerSec }
        case .upload:
            sorted = procs.sorted { $0.bytesOutPerSec > $1.bytesOutPerSec }
        case .totalBytes:
            sorted = procs.sorted { $0.totalBytes > $1.totalBytes }
        case .name:
            sorted = procs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return processSortAscending ? sorted.reversed() : sorted
    }

    func resortProcesses() {
        processBandwidths = sortProcesses(processBandwidths)
    }

    func refreshConnections() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let summary = self?.parseConnections() ?? ConnectionSummary()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.connectionSummary = summary
                // Trigger async DNS resolution for all unique IPs
                let allDests = summary.internetDestinations + summary.lanDestinations
                for dest in allDests {
                    if let endpoint = self.parseDestinationString(dest) {
                        self.dnsCache.resolve(endpoint.host)
                    }
                }
            }
        }
    }

    private func parseConnections() -> ConnectionSummary {
        var summary = ConnectionSummary()

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["+c", "0", "-n", "-P", "-iTCP"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return summary }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return summary }

        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 10 else { continue }
            let stateToken = String(cols.last ?? "")
            guard stateToken.hasPrefix("("), stateToken.hasSuffix(")") else { continue }

            let state = String(stateToken.dropFirst().dropLast())
            guard state == "ESTABLISHED" || state == "SYN_SENT" || state == "CLOSE_WAIT" else { continue }

            // lsof +c 0 encodes spaces as \x20 in the COMMAND column
            let procName = String(cols[0]).replacingOccurrences(of: "\\x20", with: " ")
            guard let connField = cols.dropLast().last(where: { $0.contains("->") }) else { continue }
            guard let remote = parseRemoteEndpoint(from: String(connField)) else { continue }

            if isLocalAddress(remote.host) {
                summary.lanCount += 1
                summary.lanDestinations.append(remote.displayString)
                summary.lanProcesses[procName, default: 0] += 1
            } else {
                summary.internetCount += 1
                summary.internetDestinations.append(remote.displayString)
                summary.internetProcesses[procName, default: 0] += 1
            }
        }

        return summary
    }

    private func parseRemoteEndpoint(from connection: String) -> NetworkEndpoint? {
        let parts = connection.split(separator: ">", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return parseEndpoint(parts[1])
    }

    func parseDestinationString(_ destination: String) -> NetworkEndpoint? {
        parseEndpoint(destination)
    }

    private func parseEndpoint(_ endpoint: String) -> NetworkEndpoint? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["),
           let closeBracket = trimmed.firstIndex(of: "]"),
           let colon = trimmed[closeBracket...].firstIndex(of: ":") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket])
            let port = String(trimmed[trimmed.index(after: colon)...])
            guard !host.isEmpty, !port.isEmpty else { return nil }
            return NetworkEndpoint(host: host, port: port)
        }

        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        let port = String(trimmed[trimmed.index(after: colon)...])
        guard !host.isEmpty, !port.isEmpty else { return nil }
        return NetworkEndpoint(host: host, port: port)
    }

    private func isLocalAddress(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        if host.hasPrefix("fe80:") || host.hasPrefix("FE80:") { return true }
        if host.hasPrefix("fc") || host.hasPrefix("FC") || host.hasPrefix("fd") || host.hasPrefix("FD") {
            return true
        }

        if host.hasPrefix("10.") || host.hasPrefix("127.") || host.hasPrefix("169.254.") { return true }
        if host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }
}

// MARK: - Formatting Helpers

func formatBytes(_ bytes: Double) -> String {
    if bytes >= 1_073_741_824 { return String(format: "%.2f GiB", bytes / 1_073_741_824) }
    if bytes >= 1_048_576 { return String(format: "%.1f MiB", bytes / 1_048_576) }
    if bytes >= 1024 { return String(format: "%.1f KiB", bytes / 1024) }
    return String(format: "%.0f B", bytes)
}

func formatBytesRate(_ bps: Double) -> String {
    return "\(formatBytes(bps))/s"
}

func formatTotalBytes(_ bytes: UInt64) -> String {
    return formatBytes(Double(bytes))
}

// MARK: - Views

struct SparklineView: View {
    let data: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let maxVal = max((data.max() ?? 1), 1)
            let w = geo.size.width
            let h = geo.size.height

            if data.count > 1 {
                Path { path in
                    for (i, val) in data.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(data.count - 1)
                        let y = h - (h * CGFloat(val / maxVal))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, lineWidth: 1.5)

                Path { path in
                    path.move(to: CGPoint(x: 0, y: h))
                    for (i, val) in data.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(data.count - 1)
                        let y = h - (h * CGFloat(val / maxVal))
                        if i == 0 { path.addLine(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.15))
            }
        }
    }
}

struct RateCardView: View {
    let title: String
    let rate: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Text(rate)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundColor(.primary)
    }
}

struct ProcessRow: View {
    let name: String
    let count: Int
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 12, design: .monospaced))
            Spacer()
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

struct BarView: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.1))
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.5))
                    .frame(width: max(0, geo.size.width * CGFloat(min(fraction, 1.0))))
            }
        }
        .frame(height: 4)
    }
}

struct SortButton: View {
    let label: String
    let key: ProcessSortKey
    @Binding var currentKey: ProcessSortKey
    @Binding var ascending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            if currentKey == key {
                ascending.toggle()
            } else {
                currentKey = key
                ascending = key == .name
            }
            action()
        }) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: currentKey == key ? .bold : .medium))
                if currentKey == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .foregroundColor(currentKey == key ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct ProcessBandwidthRow: View {
    let proc: ProcessBandwidth
    let maxRate: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(proc.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(formatBytesRate(proc.totalPerSec))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(proc.totalPerSec > 0 ? .primary : .secondary)
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8))
                        .foregroundColor(.blue)
                    Text(formatBytesRate(proc.bytesInPerSec))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.blue)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                    Text(formatBytesRate(proc.bytesOutPerSec))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                }
                Spacer()
                if proc.connections > 1 {
                    Text("\(proc.connections) pids")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(formatTotalBytes(proc.totalBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if maxRate > 0 {
                HStack(spacing: 2) {
                    BarView(fraction: proc.bytesInPerSec / maxRate, color: .blue)
                    BarView(fraction: proc.bytesOutPerSec / maxRate, color: .orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ContentView: View {
    @StateObject private var monitor = NetworkMonitor.shared

    // MARK: - Left column: Per-Process Bandwidth
    var leftColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Per-Process Bandwidth", icon: "cpu")
                Spacer()
                Text("\(monitor.processBandwidths.count) processes")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Text("Sort:")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                ForEach(ProcessSortKey.allCases, id: \.self) { key in
                    SortButton(
                        label: key.rawValue,
                        key: key,
                        currentKey: $monitor.processSortKey,
                        ascending: $monitor.processSortAscending,
                        action: { monitor.resortProcesses() }
                    )
                }
            }

            let maxRate = monitor.processBandwidths.map { $0.totalPerSec }.max() ?? 1.0

            if monitor.processBandwidths.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Sampling network traffic...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(monitor.processBandwidths) { proc in
                        ProcessBandwidthRow(proc: proc, maxRate: maxRate)
                        Divider()
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - Right column: Overview + connections + destinations
    var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bandwidther")
                        .font(.system(size: 20, weight: .bold))
                    if let status = monitor.nettopStatus {
                        Text("Nettop unavailable: \(status)")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .lineLimit(2)
                    } else {
                        Text("All interfaces (via nettop delta mode)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    let total = monitor.connectionSummary.internetCount + monitor.connectionSummary.lanCount
                    Text("\(total) connections")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            Circle().fill(.blue).frame(width: 6, height: 6)
                            Text("\(monitor.connectionSummary.internetCount) internet")
                                .font(.system(size: 11))
                        }
                        HStack(spacing: 3) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("\(monitor.connectionSummary.lanCount) LAN")
                                .font(.system(size: 11))
                        }
                    }
                    .foregroundColor(.secondary)
                }
            }

            // Live rates
            HStack(spacing: 10) {
                RateCardView(
                    title: "DOWNLOAD",
                    rate: formatBytesRate(monitor.currentRate.bytesInPerSec),
                    icon: "arrow.down.circle.fill",
                    color: .blue
                )
                RateCardView(
                    title: "UPLOAD",
                    rate: formatBytesRate(monitor.currentRate.bytesOutPerSec),
                    icon: "arrow.up.circle.fill",
                    color: .orange
                )
            }

            // Sparkline graph
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Bandwidth (last 60s)", icon: "chart.xyaxis.line")

                ZStack(alignment: .topTrailing) {
                    SparklineView(
                        data: monitor.rateHistory.map { $0.bytesInPerSec },
                        color: .blue
                    )

                    SparklineView(
                        data: monitor.rateHistory.map { $0.bytesOutPerSec },
                        color: .orange
                    )

                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(.blue).frame(width: 12, height: 2)
                            Text("In").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(.orange).frame(width: 12, height: 2)
                            Text("Out").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }
                    .padding(4)
                    .background(.ultraThinMaterial)
                    .cornerRadius(4)
                }
                .frame(height: 80)
                .padding(8)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(8)
            }

            // Cumulative total
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Cumulative Total", icon: "clock.arrow.circlepath")
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                        Text(formatTotalBytes(monitor.totalBytesIn))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text(formatTotalBytes(monitor.totalBytesOut))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(8)
            }

            // Traffic breakdown
            HStack(alignment: .top, spacing: 12) {
                // Internet
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Internet", icon: "globe")
                    if monitor.connectionSummary.internetProcesses.isEmpty {
                        Text("No connections")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        let sorted = monitor.connectionSummary.internetProcesses.sorted { $0.value > $1.value }
                        ForEach(sorted, id: \.key) { proc, count in
                            ProcessRow(name: proc, count: count, color: .blue)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.blue.opacity(0.04))
                .cornerRadius(8)

                // LAN
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "LAN / Local", icon: "network")
                    if monitor.connectionSummary.lanProcesses.isEmpty {
                        Text("No connections")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        let sorted = monitor.connectionSummary.lanProcesses.sorted { $0.value > $1.value }
                        ForEach(sorted, id: \.key) { proc, count in
                            ProcessRow(name: proc, count: count, color: .green)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.green.opacity(0.04))
                .cornerRadius(8)
            }

            // Destinations
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Internet Destinations", icon: "mappin.and.ellipse")

                let dests = Array(Set(monitor.connectionSummary.internetDestinations)).sorted().prefix(20)
                if dests.isEmpty {
                    Text("None")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(dests), id: \.self) { dest in
                            if let endpoint = monitor.parseDestinationString(dest) {
                                let hostname = monitor.dnsCache.hostname(for: endpoint.host)
                                VStack(alignment: .leading, spacing: 1) {
                                    if let hostname = hostname {
                                        Text("\(hostname):\(endpoint.port)")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                    }
                                    Text(dest)
                                        .font(.system(size: hostname != nil ? 10 : 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            } else {
                                Text(dest)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: overview panels (scrollable independently)
            ScrollView {
                rightColumn.padding(16)
            }
            .frame(minWidth: 440)

            Divider()

            // Right: per-process (scrollable independently)
            ScrollView {
                leftColumn.padding(16)
            }
            .frame(width: 420)
        }
        .frame(width: 900, height: 700)
        .background(.background)
    }
}

// MARK: - Menu Bar Speed Icon

final class MenuBarIconGenerator {
    static func generateIcon(text: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let image = NSImage(size: NSSize(width: 66, height: 22), flipped: false) { rect in
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            style.maximumLineHeight = 10

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: style,
            ]

            let textSize = text.size(withAttributes: attributes)
            let textRect = NSRect(
                x: 0,
                y: (rect.height - textSize.height) / 2 - 1.5,
                width: 66,
                height: textSize.height
            )

            text.draw(in: textRect, withAttributes: attributes)
            return true
        }

        image.isTemplate = true
        return image
    }

    static func formatCompactRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_073_741_824 { return String(format: "%4.0f GiB", bytesPerSec / 1_073_741_824) }
        if bytesPerSec >= 1_048_576 { return String(format: "%4.0f MiB", bytesPerSec / 1_048_576) }
        if bytesPerSec >= 1024 { return String(format: "%4.0f KiB", bytesPerSec / 1024) }
        return String(format: "%4.0f   B", bytesPerSec)
    }

    static func menuBarText(rate: BandwidthRate) -> String {
        let up = formatCompactRate(rate.bytesOutPerSec)
        let down = formatCompactRate(rate.bytesInPerSec)
        return "\(up)/s ↑\n\(down)/s ↓"
    }
}

// MARK: - App Delegate for Menu Bar

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    private var rateObservation: AnyCancellable?
    private var lastMenuBarText: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = NetworkMonitor.shared

        // Create status bar item with variable width for speed text
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let initialText = MenuBarIconGenerator.menuBarText(rate: .zero)
        lastMenuBarText = initialText
        if let button = statusItem.button {
            button.image = MenuBarIconGenerator.generateIcon(text: initialText)
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Observe rate changes and update the menu bar icon only when text changes
        rateObservation = monitor.$currentRate.receive(on: RunLoop.main).sink { [weak self] rate in
            guard let self = self else { return }
            let text = MenuBarIconGenerator.menuBarText(rate: rate)
            if text != self.lastMenuBarText {
                self.lastMenuBarText = text
                self.statusItem.button?.image = MenuBarIconGenerator.generateIcon(text: text)
            }
        }

        // Create the popover with our content
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 900, height: 750)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView())
        self.popover = popover

        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NetworkMonitor.shared.beginDetailPolling()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        NetworkMonitor.shared.endDetailPolling()
    }
}

// MARK: - App Entry Point

@main
struct BandwidtherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
