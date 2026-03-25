import SwiftUI
import Darwin
import Foundation

// MARK: - Data Models

struct InterfaceSnapshot {
    let name: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    let packetsIn: UInt64
    let packetsOut: UInt64
    let timestamp: Date
}

struct BandwidthRate {
    let bytesInPerSec: Double
    let bytesOutPerSec: Double

    var totalPerSec: Double { bytesInPerSec + bytesOutPerSec }

    static let zero = BandwidthRate(bytesInPerSec: 0, bytesOutPerSec: 0)
}

struct ConnectionInfo: Identifiable {
    let id = UUID()
    let process: String
    let remoteIP: String
    let remotePort: String
    let isLocal: Bool
    let state: String
}

struct ConnectionSummary {
    var internetCount: Int = 0
    var lanCount: Int = 0
    var internetProcesses: [String: Int] = [:]
    var lanProcesses: [String: Int] = [:]
    var internetDestinations: [String] = []
    var lanDestinations: [String] = []
    var internetBytesIn: Double = 0
    var internetBytesOut: Double = 0
    var lanBytesIn: Double = 0
    var lanBytesOut: Double = 0
}

// MARK: - Network Monitor

class NetworkMonitor: ObservableObject {
    @Published var currentRate = BandwidthRate.zero
    @Published var totalBytesIn: UInt64 = 0
    @Published var totalBytesOut: UInt64 = 0
    @Published var connectionSummary = ConnectionSummary()
    @Published var primaryInterface: String = "en0"
    @Published var rateHistory: [BandwidthRate] = []

    private var previousSnapshot: InterfaceSnapshot?
    private var rateTimer: Timer?
    private var connTimer: Timer?
    private let maxHistory = 60

    init() {
        refreshInterfaceStats()
        refreshConnections()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshInterfaceStats()
        }
        connTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshConnections()
        }
    }

    deinit {
        rateTimer?.invalidate()
        connTimer?.invalidate()
    }

    func refreshInterfaceStats() {
        guard let snapshot = getInterfaceStats(name: primaryInterface) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.totalBytesIn = snapshot.bytesIn
            self.totalBytesOut = snapshot.bytesOut

            if let prev = self.previousSnapshot {
                let dt = snapshot.timestamp.timeIntervalSince(prev.timestamp)
                if dt > 0 {
                    let rate = BandwidthRate(
                        bytesInPerSec: Double(snapshot.bytesIn - prev.bytesIn) / dt,
                        bytesOutPerSec: Double(snapshot.bytesOut - prev.bytesOut) / dt
                    )
                    self.currentRate = rate
                    self.rateHistory.append(rate)
                    if self.rateHistory.count > self.maxHistory {
                        self.rateHistory.removeFirst()
                    }
                }
            }
            self.previousSnapshot = snapshot
        }
    }

    func refreshConnections() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let summary = self?.parseConnections() ?? ConnectionSummary()
            DispatchQueue.main.async {
                self?.connectionSummary = summary
            }
        }
    }

    private func getInterfaceStats(name: String) -> InterfaceSnapshot? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let ifaName = String(cString: ptr.pointee.ifa_name)
            guard ifaName == name else { continue }
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let data = unsafeBitCast(ptr.pointee.ifa_data, to: UnsafeMutablePointer<if_data>.self)
            return InterfaceSnapshot(
                name: ifaName,
                bytesIn: UInt64(data.pointee.ifi_ibytes),
                bytesOut: UInt64(data.pointee.ifi_obytes),
                packetsIn: UInt64(data.pointee.ifi_ipackets),
                packetsOut: UInt64(data.pointee.ifi_opackets),
                timestamp: Date()
            )
        }
        return nil
    }

    private func parseConnections() -> ConnectionSummary {
        var summary = ConnectionSummary()

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-an", "-f", "inet"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return summary }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return summary }

        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 6 else { continue }
            let state = String(cols.last ?? "")
            guard state == "ESTABLISHED" || state == "SYN_SENT" || state == "CLOSE_WAIT" else { continue }

            let foreign = String(cols[4])
            guard let lastDot = foreign.lastIndex(of: ".") else { continue }
            let ip = String(foreign[foreign.startIndex..<lastDot])
            let port = String(foreign[foreign.index(after: lastDot)...])

            let isLocal = isPrivateIP(ip)
            let dest = "\(ip):\(port)"

            if isLocal {
                summary.lanCount += 1
                summary.lanDestinations.append(dest)
            } else {
                summary.internetCount += 1
                summary.internetDestinations.append(dest)
            }
        }

        // Get process info via lsof
        let pipe2 = Pipe()
        let proc2 = Process()
        proc2.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc2.arguments = ["-i", "-n", "-P"]
        proc2.standardOutput = pipe2
        proc2.standardError = FileHandle.nullDevice

        do { try proc2.run() } catch { return summary }
        let data2 = pipe2.fileHandleForReading.readDataToEndOfFile()
        proc2.waitUntilExit()

        if let output2 = String(data: data2, encoding: .utf8) {
            for line in output2.split(separator: "\n") {
                guard line.contains("ESTABLISHED") else { continue }
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                guard cols.count >= 9 else { continue }
                let procName = String(cols[0])
                let connStr = String(cols[8])
                let parts = connStr.split(separator: ">")
                guard parts.count == 2 else { continue }
                let remote = String(parts[1])
                guard let lastColon = remote.lastIndex(of: ":") else { continue }
                let ip = String(remote[remote.startIndex..<lastColon])
                if isPrivateIP(ip) {
                    summary.lanProcesses[procName, default: 0] += 1
                } else {
                    summary.internetProcesses[procName, default: 0] += 1
                }
            }
        }

        return summary
    }

    private func isPrivateIP(_ ip: String) -> Bool {
        if ip.hasPrefix("10.") || ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { return true }
        if ip.hasPrefix("192.168.") { return true }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }
}

// MARK: - Formatting Helpers

func formatBytes(_ bytes: Double) -> String {
    if bytes >= 1_073_741_824 { return String(format: "%.2f GB", bytes / 1_073_741_824) }
    if bytes >= 1_048_576 { return String(format: "%.1f MB", bytes / 1_048_576) }
    if bytes >= 1024 { return String(format: "%.1f KB", bytes / 1024) }
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

struct ContentView: View {
    @StateObject private var monitor = NetworkMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bandwidther")
                            .font(.system(size: 20, weight: .bold))
                        Text("Interface: \(monitor.primaryInterface)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
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

                // Totals since boot
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Total Since Boot", icon: "clock.arrow.circlepath")
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
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 3) {
                            ForEach(Array(dests), id: \.self) { dest in
                                Text(dest)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(8)
            }
            .padding(16)
        }
        .frame(width: 480, height: 680)
    }
}

// MARK: - App Entry Point

@main
struct BandwidtherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
