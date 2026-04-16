import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "StatusMonitor", category: "polling")

@MainActor
@Observable
class StatusManager {
    var snapshots: [ProviderSnapshot] = []
    var providers: [Provider] = []
    var worstStatus: ComponentStatus = .operational
    var isPolling = false

    var onWorstStatusChanged: ((ComponentStatus) -> Void)?
    var onPollCycleComplete: (() -> Void)?
    private var timers: [UUID: Timer] = [:]
    private var previousStatuses: [UUID: ComponentStatus] = [:]
    private var failureCounts: [UUID: Int] = [:]
    private var lastFailure: [UUID: Date] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        loadProviders()
    }

    // MARK: - Provider Persistence

    func loadProviders() {
        guard let data = UserDefaults.standard.data(forKey: "providers") else {
            providers = []
            return
        }
        do {
            let saved = try JSONDecoder().decode([Provider].self, from: data)
            if !saved.isEmpty {
                providers = saved
                if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                    UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                }
            } else {
                providers = []
            }
        } catch {
            // Schema mismatch or corruption — back up the bad blob so it can be
            // recovered manually, then start fresh rather than silently empty.
            let backupKey = "providers_corrupt_\(Int(Date().timeIntervalSince1970))"
            UserDefaults.standard.set(data, forKey: backupKey)
            logger.error("Failed to decode persisted providers (\(error.localizedDescription)). Backed up raw data at \(backupKey).")
            providers = []
        }
    }

    func saveProviders() {
        do {
            let data = try JSONEncoder().encode(providers)
            UserDefaults.standard.set(data, forKey: "providers")
        } catch {
            logger.error("Failed to encode providers for persistence: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func addProvider(_ provider: Provider) -> Bool {
        guard provider.hasValidURL else {
            logger.error("Refused to add provider with invalid URL: \(provider.baseURL)")
            return false
        }
        guard !providers.contains(where: { $0.baseURL == provider.baseURL }) else {
            logger.warning("Refused to add duplicate provider: \(provider.baseURL)")
            return false
        }
        providers.append(provider)
        saveProviders()
        schedulePolling(for: provider)
        Task { await poll(provider: provider) }
        // Mark onboarding complete when first provider is added
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }
        logger.info("Added provider: \(provider.name)")
        return true
    }

    func updatePollInterval(for provider: Provider, seconds: Int) {
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[idx].pollIntervalSeconds = max(30, seconds)
        saveProviders()
        if isPolling {
            schedulePolling(for: providers[idx])
        }
    }

    func toggleMute(for provider: Provider) {
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[idx].isMuted.toggle()
        saveProviders()
        recalcWorstStatus()
    }

    func removeProvider(_ provider: Provider) {
        timers[provider.id]?.invalidate()
        timers.removeValue(forKey: provider.id)
        providers.removeAll { $0.id == provider.id }
        snapshots.removeAll { $0.id == provider.id }
        previousStatuses.removeValue(forKey: provider.id)
        failureCounts.removeValue(forKey: provider.id)
        lastFailure.removeValue(forKey: provider.id)
        saveProviders()
        recalcWorstStatus()
    }

    // MARK: - Polling

    func startPolling() {
        isPolling = true
        let enabled = providers.filter(\.isEnabled)
        for provider in enabled {
            schedulePolling(for: provider)
        }
        // Initial poll with concurrency cap
        Task {
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for provider in enabled {
                    if running >= maxConcurrentPolls {
                        await group.next()
                        running -= 1
                    }
                    group.addTask { @MainActor [weak self] in
                        await self?.poll(provider: provider)
                    }
                    running += 1
                }
            }
        }
    }

    func stopPolling() {
        isPolling = false
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
    }

    private func schedulePolling(for provider: Provider) {
        let providerId = provider.id
        timers[providerId]?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(provider.pollIntervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Look up the current provider by ID so mute/name/URL edits take effect
                // without waiting for a re-schedule.
                guard let self = self,
                      let current = self.providers.first(where: { $0.id == providerId }) else { return }
                await self.poll(provider: current)
            }
        }
        timers[providerId] = timer
    }

    private let maxConcurrentPolls = 6

    func pollAll() {
        let enabled = providers.filter(\.isEnabled)
        Task {
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for provider in enabled {
                    if running >= maxConcurrentPolls {
                        await group.next()
                        running -= 1
                    }
                    group.addTask { @MainActor [weak self] in
                        await self?.poll(provider: provider)
                    }
                    running += 1
                }
            }
            onPollCycleComplete?()
        }
    }

    private func poll(provider: Provider) async {
        // Exponential backoff: skip if we failed recently.
        // `max(0, ...)` guards against wall-clock rollback (NTP/timezone) that
        // would otherwise leave the gate permanently closed.
        if let failures = failureCounts[provider.id], failures > 0,
           let lastFail = lastFailure[provider.id] {
            let backoffSeconds = min(Double(provider.pollIntervalSeconds) * pow(2, Double(min(failures, 5))), 3600)
            let elapsed = max(0, Date().timeIntervalSince(lastFail))
            if elapsed < backoffSeconds {
                return
            }
        }

        guard let url = provider.apiURL else {
            recordFailure(for: provider)
            updateSnapshot(for: provider, error: "Invalid URL — must be https:// with a valid host")
            return
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                recordFailure(for: provider)
                updateSnapshot(for: provider, error: "Non-HTTP response")
                return
            }
            guard (200...299).contains(http.statusCode) else {
                logger.error("Poll HTTP \(http.statusCode) for \(provider.name)")
                recordFailure(for: provider)
                updateSnapshot(for: provider, error: httpErrorMessage(for: http.statusCode))
                return
            }

            // Success — reset backoff
            failureCounts[provider.id] = 0

            switch provider.type {
            case .statuspage:
                do {
                    try parseStatuspage(data: data, provider: provider)
                } catch let error as DecodingError {
                    logger.error("Statuspage schema mismatch for \(provider.name): \(String(describing: error))")
                    updateSnapshot(for: provider, error: "Status format not recognized")
                }
            case .rss:
                do {
                    try parseRSS(data: data, provider: provider)
                } catch {
                    logger.error("RSS parse failed for \(provider.name): \(error.localizedDescription)")
                    updateSnapshot(for: provider, error: "Could not parse RSS feed")
                }
            }
        } catch let urlError as URLError {
            logger.error("Network error [\(urlError.code.rawValue)] for \(provider.name): \(urlError.localizedDescription)")
            recordFailure(for: provider)
            updateSnapshot(for: provider, error: networkErrorMessage(for: urlError))
        } catch {
            logger.error("Poll failed for \(provider.name): \(error.localizedDescription)")
            recordFailure(for: provider)
            updateSnapshot(for: provider, error: "Unable to read status page")
        }
    }

    private func httpErrorMessage(for code: Int) -> String {
        switch code {
        case 401, 403: return "Access denied (\(code))"
        case 404: return "Status page not found (404) — URL may have changed"
        case 429: return "Rate limited (429)"
        case 500...599: return "Status page unavailable (\(code))"
        case 300...399: return "Unexpected redirect (\(code))"
        default: return "HTTP \(code)"
        }
    }

    private func networkErrorMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "No internet connection"
        case .timedOut: return "Request timed out"
        case .cannotFindHost, .dnsLookupFailed: return "Cannot find host"
        case .cannotConnectToHost: return "Cannot connect to host"
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "Secure connection failed"
        default: return "Network error"
        }
    }

    private func recordFailure(for provider: Provider) {
        let count = (failureCounts[provider.id] ?? 0) + 1
        failureCounts[provider.id] = count
        lastFailure[provider.id] = Date()
        let backoff = min(Double(provider.pollIntervalSeconds) * pow(2, Double(min(count, 5))), 3600)
        logger.warning("Poll failure #\(count) for \(provider.name), backing off \(Int(backoff))s")
    }

    // MARK: - Statuspage JSON Parsing

    private static func parseDate(_ string: String) -> Date? {
        iso8601.date(from: string) ?? iso8601NoFraction.date(from: string)
    }

    private func parseStatuspage(data: Data, provider: Provider) throws {
        let decoder = JSONDecoder()
        let summary = try decoder.decode(StatuspageSummary.self, from: data)

        let indicatorStatus = ComponentStatus(fromIndicator: summary.status.indicator)

        // Build group name lookup for child components (e.g., Asana has US, EU, Japan groups)
        var groupNames: [String: String] = [:]
        for comp in summary.components {
            if comp.group == true {
                groupNames[comp.id] = comp.name
            }
        }

        let components = summary.components
            .filter { $0.group != true }  // exclude group headers, keep children
            .map { comp -> ComponentSnapshot in
                var displayName = comp.name
                if let groupId = comp.groupId, let groupName = groupNames[groupId] {
                    displayName = "\(comp.name) (\(groupName))"
                }
                return ComponentSnapshot(id: comp.id, name: displayName, status: ComponentStatus(fromStatuspage: comp.status))
            }

        // Overall status is the worst of the Atlassian indicator and any
        // component-level status — indicators sometimes lag behind components
        // during rapid incidents.
        let componentMax = components.map(\.status).max() ?? .operational
        let overall = max(indicatorStatus, componentMax)

        let incidents = (summary.incidents ?? []).prefix(5).map { incident in
            let updates = (incident.incidentUpdates ?? []).map { update in
                IncidentUpdateSnapshot(
                    id: update.id,
                    status: update.status,
                    body: update.body,
                    createdAt: Self.parseDate(update.createdAt)
                )
            }
            return IncidentSnapshot(
                id: incident.id,
                name: incident.name,
                impact: ComponentStatus(fromIndicator: incident.impact),
                status: incident.status,
                latestUpdate: incident.incidentUpdates?.first?.body,
                updatedAt: Self.parseDate(incident.updatedAt),
                updates: updates
            )
        }

        let snapshot = ProviderSnapshot(
            id: provider.id,
            name: provider.name,
            overallStatus: overall,
            components: components,
            activeIncidents: Array(incidents),
            lastUpdated: Date(),
            error: nil
        )

        applySnapshot(snapshot, for: provider)
    }

    // MARK: - RSS Parsing (basic)

    static func rssStatusHeuristic(title: String, description: String) -> ComponentStatus {
        let text = (title + " " + description).lowercased()
        // Resolved-first: "Resolved: Major outage" describes a healed incident, not an active one.
        if text.contains("resolved") || text.contains("completed") || text.contains("closed") {
            return .operational
        }
        if text.contains("major") || text.contains("outage") { return .majorOutage }
        if text.contains("partial") { return .partialOutage }
        if text.contains("degraded") || text.contains("elevated") { return .degradedPerformance }
        if text.contains("operational") { return .operational }
        return .unknown
    }

    private func parseRSS(data: Data, provider: Provider) throws {
        let parser = RSSStatusParser(data: data)
        let items = try parser.parse()

        // Heuristic: check titles/descriptions for outage keywords.
        // Empty feed is treated as operational — for status-page RSS, no recent
        // items typically means no incidents.
        let overall: ComponentStatus = items.first.map { item in
            Self.rssStatusHeuristic(title: item.title, description: item.description)
        } ?? .operational

        let incidents = items.prefix(5).map { item -> IncidentSnapshot in
            let itemStatus = Self.rssStatusHeuristic(title: item.title, description: item.description)
            return IncidentSnapshot(
                id: item.guid ?? item.title,
                name: item.title,
                impact: itemStatus,
                status: itemStatus.label,
                latestUpdate: item.description,
                updatedAt: item.pubDate
            )
        }

        let snapshot = ProviderSnapshot(
            id: provider.id,
            name: provider.name,
            overallStatus: overall,
            components: [],
            activeIncidents: Array(incidents),
            lastUpdated: Date(),
            error: nil
        )

        applySnapshot(snapshot, for: provider)
    }

    // MARK: - Snapshot Management

    private func applySnapshot(_ snapshot: ProviderSnapshot, for provider: Provider) {
        // Guard against races: the provider may have been removed while this
        // poll was in flight, and its mute state may have been toggled.
        guard let current = providers.first(where: { $0.id == provider.id }) else { return }

        let previousStatus = previousStatuses[provider.id]

        if let idx = snapshots.firstIndex(where: { $0.id == provider.id }) {
            snapshots[idx] = snapshot
        } else {
            snapshots.append(snapshot)
        }

        // Notify on status change (not on first poll, skip if muted).
        // Read mute from the current provider, not the captured one.
        if !current.isMuted, let prev = previousStatus, prev != snapshot.overallStatus {
            NotificationService.shared.notify(
                providerId: current.id,
                provider: current.name,
                from: prev,
                to: snapshot.overallStatus,
                incident: snapshot.activeIncidents.first?.name
            )
        }

        previousStatuses[provider.id] = snapshot.overallStatus
        recalcWorstStatus()
        onPollCycleComplete?()
    }

    /// Marks a provider's snapshot as errored while preserving the last-good
    /// status/components/incidents. This way a transient parse or network
    /// failure mid-incident doesn't wipe user-visible state back to green.
    private func updateSnapshot(for provider: Provider, error: String) {
        guard providers.contains(where: { $0.id == provider.id }) else { return }

        let snapshot: ProviderSnapshot
        if let idx = snapshots.firstIndex(where: { $0.id == provider.id }) {
            let prior = snapshots[idx]
            snapshot = ProviderSnapshot(
                id: prior.id,
                name: provider.name,
                overallStatus: prior.error == nil ? prior.overallStatus : .unknown,
                components: prior.error == nil ? prior.components : [],
                activeIncidents: prior.error == nil ? prior.activeIncidents : [],
                lastUpdated: prior.lastUpdated, // keep last-known-good time
                error: error
            )
            snapshots[idx] = snapshot
        } else {
            snapshot = ProviderSnapshot(
                id: provider.id,
                name: provider.name,
                overallStatus: .unknown,
                components: [],
                activeIncidents: [],
                lastUpdated: Date(),
                error: error
            )
            snapshots.append(snapshot)
        }
        recalcWorstStatus()
        onPollCycleComplete?()
    }

    func recalcWorstStatus() {
        let mutedIds = Set(providers.filter(\.isMuted).map(\.id))
        // Include errored snapshots: they carry the last-good overallStatus,
        // and `.unknown` (no prior data) has severity 1 so it surfaces above
        // "operational" but is overridden by any real degraded/outage state.
        let newStatus = snapshots
            .filter { !mutedIds.contains($0.id) }
            .map(\.overallStatus)
            .max() ?? .operational
        if newStatus != worstStatus {
            worstStatus = newStatus
            onWorstStatusChanged?(newStatus)
        }
    }

    /// Count of providers whose most recent poll failed.
    var unreachableCount: Int {
        snapshots.filter { $0.error != nil }.count
    }
}
