# Bandwidther Code Walkthrough

*2026-03-25T16:32:02Z by Showboat 0.6.1*
<!-- showboat-id: 3d401f45-e9d4-4f21-a008-db165c66369d -->

Bandwidther is a native macOS menu bar app that monitors per-process network bandwidth in real time. The entire application lives in a single file — `BandwidtherApp.swift` — roughly 1,000 lines of Swift that combine data collection (shelling out to `nettop` and `netstat`/`lsof`), a reverse-DNS cache, and a SwiftUI interface rendered inside an NSPopover anchored to the menu bar. Let's walk through it layer by layer.

## 1. Data Models (lines 8–45)

The app defines four small data types that flow through the entire pipeline:

```bash
sed -n '8,45p' BandwidtherApp.swift
```

```output
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
```

- **`BandwidthRate`** — a single snapshot of download/upload bytes-per-second. The sparkline graph stores 60 of these.
- **`ProcessBandwidth`** — one row in the per-process table: name, current rates, cumulative totals, and PID count. Conforms to `Identifiable` (keyed on process name) so SwiftUI `ForEach` can diff it.
- **`ProcessSortKey`** — the five columns the user can sort by. `CaseIterable` drives the sort-button bar.
- **`ConnectionSummary`** — aggregated connection counts and destination lists, split into internet vs LAN. Populated by `netstat`/`lsof` parsing.

## 2. Reverse DNS Cache (lines 49–103)

The `DNSCache` class resolves IP addresses to hostnames asynchronously so the "Internet Destinations" list can show human-readable names.

```bash
sed -n '49,103p' BandwidtherApp.swift
```

```output
class DNSCache: ObservableObject {
    @Published var resolved: [String: String] = [:]  // ip -> hostname
    private var pending: Set<String> = []
    private let queue = DispatchQueue(label: "dns-resolver", attributes: .concurrent)

    func resolve(_ ip: String) {
        // Already resolved or in-flight
        if resolved[ip] != nil || pending.contains(ip) { return }
        pending.insert(ip)

        queue.async { [weak self] in
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST
            hints.ai_family = AF_INET

            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, ip, &sa.sin_addr)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &sa) { saPtr in
                saPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    getnameinfo(sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, 0)
                }
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
```

Key design points:

- **Deduplication** — the `pending` set prevents multiple in-flight lookups for the same IP. Once resolved (or failed), the IP is stored in `resolved` so it is never retried.
- **Failure sentinel** — failed lookups store an empty string (`""`) rather than `nil`. This means `resolved[ip] != nil` is true for failures too, preventing infinite retries. The `hostname(for:)` accessor filters these out.
- **Low-level POSIX DNS** — uses `getnameinfo` directly via Darwin/C interop rather than Foundation's higher-level DNS APIs. It builds a `sockaddr_in` from the IP string, then calls `getnameinfo` for reverse lookup. A subtlety: `getnameinfo` returns the original IP unchanged when it cannot resolve, so the code explicitly checks `resolved != ip`.
- **Thread safety** — lookups run on a concurrent dispatch queue; results are dispatched back to the main queue to update `@Published` properties, which triggers SwiftUI redraws.

## 3. Nettop Parser (lines 106–190)

This is the heart of the bandwidth measurement. The app shells out to `/usr/bin/nettop`, a macOS system tool that reports per-process network statistics. The parser handles nettop's CSV output format.

```bash
sed -n '155,190p' BandwidtherApp.swift
```

```output
func runNettop() -> NettopResult {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    // -P: per-process summary, -L 2: two samples (first=cumulative, second=delta),
    // -s 1: 1 second interval, -x: raw numbers, -n: no DNS, -J: only these columns
    proc.arguments = ["-P", "-L", "2", "-s", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice

    do { try proc.run() } catch { return NettopResult() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    guard let output = String(data: data, encoding: .utf8) else { return NettopResult() }

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

    var result = NettopResult()
    if blocks.count >= 1 { result.totals = parseNettopCSVBlock(blocks[0]) }
    if blocks.count >= 2 { result.deltas = parseNettopCSVBlock(blocks[1]) }
    return result
}
```

The nettop invocation is carefully tuned:

- **`-P`** — per-process summary mode (aggregates all flows per process)
- **`-L 2`** — emit exactly two samples, then exit. The first sample contains cumulative byte counts since each process started; the second contains the delta (bytes transferred during the 1-second interval).
- **`-s 1`** — one-second interval between samples
- **`-x`** — raw numeric output (no human-friendly formatting)
- **`-n`** — skip DNS resolution (the app handles this itself)
- **`-J bytes_in,bytes_out`** — restrict output to just these two columns

The output is CSV with a header line starting `,bytes_in`. The parser splits on these header lines to separate the two sample blocks, then calls `parseNettopCSVBlock` on each.

```bash
sed -n '120,153p' BandwidtherApp.swift
```

```output
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
```

The CSV parser handles a quirk of nettop's output: process names include the PID as a dot-suffix (e.g. `Safari.12345`). The parser finds the last `.`, checks if the suffix is numeric, and splits accordingly. This correctly handles names with dots or spaces like `LM Studio.1234`.

Multiple PIDs for the same process name are **aggregated** — their byte counts are summed and their PIDs collected into a set. This gives the "pids" count shown in the UI (e.g. "3 pids" for a multi-process app like Chrome).

## 4. NetworkMonitor — the central coordinator (lines 194–402)

`NetworkMonitor` is an `ObservableObject` that ties everything together. It owns two repeating timers and publishes all the state that the UI observes.

```bash
sed -n '194,218p' BandwidtherApp.swift
```

```output
class NetworkMonitor: ObservableObject {
    @Published var currentRate = BandwidthRate.zero
    @Published var totalBytesIn: UInt64 = 0
    @Published var totalBytesOut: UInt64 = 0
    @Published var connectionSummary = ConnectionSummary()
    @Published var dnsCache = DNSCache()
    @Published var rateHistory: [BandwidthRate] = []
    @Published var processBandwidths: [ProcessBandwidth] = []
    @Published var processSortKey: ProcessSortKey = .totalRate
    @Published var processSortAscending: Bool = false

    private var connTimer: Timer?
    private var nettopTimer: Timer?
    private let maxHistory = 60

    init() {
        refreshConnections()
        connTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshConnections()
        }
        refreshNettop()
        nettopTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshNettop()
        }
    }
```

Two independent polling loops run every 3 seconds:

1. **`refreshNettop()`** — dispatches `runNettop()` to a background queue, then processes results on the main thread via `processNettopResult()`. This updates: current rates, cumulative totals, the sparkline history (capped at 60 entries = 3 minutes of data), and the per-process table.

2. **`refreshConnections()`** — runs `netstat -an -f inet` to count ESTABLISHED/SYN_SENT/CLOSE_WAIT TCP connections, then runs `lsof -i -n -P` to map connections to process names. Results are classified as internet vs LAN.

```bash
sed -n '234,281p' BandwidtherApp.swift
```

```output
    private func processNettopResult(_ result: NettopResult) {
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
        rateHistory.append(rate)
        if rateHistory.count > maxHistory {
            rateHistory.removeFirst()
        }

        processBandwidths = sortProcesses(procs)
    }
```

`processNettopResult` merges the two nettop sample blocks. It unions the process names from both blocks (a process might appear in totals but not deltas if it was idle during the sample interval, or vice versa). Processes with zero cumulative bytes are filtered out to keep the list clean. The global rate sums are what drive the download/upload rate cards and the sparkline.

### Connection parsing and IP classification (lines 304–402)

The connection-tracking pipeline uses two system tools in sequence:

```bash
sed -n '320,402p' BandwidtherApp.swift
```

```output
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
```

**Step 1: `netstat -an -f inet`** — lists all IPv4 sockets. The parser filters for active states (ESTABLISHED, SYN_SENT, CLOSE_WAIT) and extracts the foreign address. macOS netstat uses dot-separated `ip.port` format (e.g. `142.250.80.46.443`), so the code splits on the *last* dot to separate IP from port.

**Step 2: `lsof -i -n -P`** — maps sockets to process names. The `-n` flag skips DNS (speed), `-P` shows numeric ports. It parses the `local->remote` connection string from column 9, extracting the remote IP to classify as internet or LAN.

**`isPrivateIP`** classifies by RFC 1918 ranges: `10.x`, `172.16-31.x`, `192.168.x`, plus loopback (`127.x`) and link-local (`169.254.x`).

After `refreshConnections` completes, it also kicks off reverse DNS resolution for every destination IP through the `DNSCache`.

## 5. Formatting Helpers (lines 407–420)

Three small functions convert raw byte counts to human-readable strings:

```bash
sed -n '407,420p' BandwidtherApp.swift
```

```output
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
```

Standard binary prefix formatting (KB/MB/GB with 1024-based thresholds). `formatBytesRate` appends "/s" for live rates; `formatTotalBytes` bridges from `UInt64` to the `Double`-based formatter.

## 6. SwiftUI Views (lines 424–893)

The UI is built from several composable views. Let's look at the key ones.

### SparklineView (lines 424–460)

Draws a real-time bandwidth graph as a filled line chart:

```bash
sed -n '424,460p' BandwidtherApp.swift
```

```output
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
```

The sparkline renders two overlapping `Path` shapes using `GeometryReader` to fill available space:

1. **Stroke path** — the visible line, drawn point-to-point with `lineWidth: 1.5`
2. **Fill path** — the same curve closed down to the bottom edge, filled at 15% opacity for the "area under the curve" effect

The Y-axis auto-scales to the current maximum value (`maxVal`), so small fluctuations are visible even when overall traffic is low. Two instances are layered in the UI — blue for download, orange for upload.

### Small reusable components (lines 462–571)

Several utility views keep the main layout clean:

- **`RateCardView`** — the colored download/upload boxes showing icon + label + large monospaced rate
- **`SectionHeader`** — icon + bold title, used consistently across sections
- **`ProcessRow`** — a single row in the internet/LAN process lists (colored dot + name + count)
- **`BarView`** — a tiny proportional bar (4px tall) used in per-process rows to visualize relative bandwidth
- **`SortButton`** — a clickable column header that tracks active sort key and toggles ascending/descending. The active key is rendered bold with a chevron indicator

### ProcessBandwidthRow (lines 573–623)

Each process in the left column is rendered by this view:

```bash
sed -n '573,623p' BandwidtherApp.swift
```

```output
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
```

Each row packs three tiers of information:
1. **Top line** — process name (monospaced) + combined rate (bold, dimmed if zero)
2. **Detail line** — blue download rate, orange upload rate, PID count (if >1), and cumulative total
3. **Bar chart** — two side-by-side `BarView` instances showing download/upload as fractions of the highest-rate process. This makes it easy to visually spot which process is dominating bandwidth.

### ContentView — the main layout (lines 626–893)

The `ContentView` assembles everything into a two-column popover:

```bash
sed -n '874,893p' BandwidtherApp.swift
```

```output
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
```

The layout is a fixed 900x700 `HStack` with two independently-scrollable `ScrollView` columns separated by a `Divider`:

- **Left column (440pt min)** — the overview: app title, connection counts, download/upload rate cards, sparkline chart, cumulative totals, internet/LAN process breakdowns, and the destination list with reverse DNS
- **Right column (420pt)** — the per-process bandwidth table with sort controls

Each column scrolls independently, so you can browse a long process list without losing sight of the overview (or vice versa).

The `ContentView` creates a single `@StateObject` `NetworkMonitor` — this is the sole source of truth. All the `@Published` properties on the monitor drive SwiftUI's reactive updates automatically.

## 7. Menu Bar Integration (lines 906–996)

The final section wires the SwiftUI view into macOS's menu bar as a popover.

```bash
sed -n '948,996p' BandwidtherApp.swift
```

```output
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item first, before changing activation policy
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Bandwidther")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create the popover with our content
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 900, height: 750)
        popover.behavior = .transient
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
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
```

The `AppDelegate` handles the AppKit side of menu bar integration:

1. **`applicationDidFinishLaunching`** creates the status bar item with a system SF Symbol (`arrow.up.arrow.down`) as the icon. It then creates an `NSPopover` with `.transient` behavior (clicks outside dismiss it) containing the SwiftUI `ContentView` wrapped in `NSHostingController`. Finally, `NSApp.setActivationPolicy(.accessory)` hides the app from the Dock — it lives entirely in the menu bar.

2. **`togglePopover`** — the click handler. Shows or hides the popover anchored below the status item. On show, it calls `activate(ignoringOtherApps:)` and `makeKey()` to ensure the popover gets keyboard focus.

3. **`BandwidtherApp`** — the `@main` entry point. Uses `@NSApplicationDelegateAdaptor` to bridge SwiftUI's `App` protocol to the AppKit delegate. The `body` contains only an empty `Settings` scene — all actual UI comes through the popover.

## 8. Data Flow Summary

Here's how it all fits together at runtime:

```
@main BandwidtherApp
  └─ AppDelegate
       └─ NSPopover ─── ContentView
                           └─ @StateObject NetworkMonitor
                                ├── Timer (3s) → refreshNettop()
                                │     └─ runNettop() → Process("/usr/bin/nettop")
                                │         └─ parseNettopCSVBlock() × 2
                                │             └─ processNettopResult()
                                │                 ├─ currentRate, totalBytesIn/Out
                                │                 ├─ rateHistory (sparkline)
                                │                 └─ processBandwidths (table)
                                │
                                └── Timer (3s) → refreshConnections()
                                      ├─ Process("/usr/sbin/netstat") → connection counts
                                      ├─ Process("/usr/sbin/lsof") → process mapping
                                      ├─ isPrivateIP() → internet vs LAN split
                                      └─ DNSCache.resolve() → reverse DNS
```

Every `@Published` property change triggers SwiftUI to re-render only the affected views. The entire app — data collection, DNS resolution, formatting, and a polished two-column interface — fits in a single ~1000-line file with no dependencies beyond the macOS system frameworks.

## 9. Build and Run

The app compiles with a single `swiftc` invocation — no Xcode project needed:

```bash
cat README.md | grep -A2 'swiftc'
```

````output
swiftc -parse-as-library -framework SwiftUI -framework AppKit -o Bandwidther BandwidtherApp.swift
./Bandwidther
```
````

The `-parse-as-library` flag is needed because the file uses `@main` rather than a top-level code entry point. The two `-framework` flags link SwiftUI and AppKit. No third-party dependencies, no Package.swift, no Xcode project — just one Swift file and the system toolchain.
