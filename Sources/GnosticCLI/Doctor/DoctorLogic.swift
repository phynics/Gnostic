// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import GnosticHost

/// One result of `gnostic doctor`.
public struct DoctorFinding: Codable, Sendable, Equatable {
    /// The severity of a finding. Only ``Severity/error`` makes the Node unhealthy.
    public enum Severity: String, Codable, Sendable {
        case ok
        case warning
        case error
    }

    /// The check name, for example `manifest` or `executor`.
    public let check: String
    /// The severity.
    public let severity: Severity
    /// A one-line, actionable result.
    public let message: String
    /// The manifest path the finding belongs to, when there is one.
    public let path: String?
    /// A remediation hint, shown when the severity is not `ok`.
    public let hint: String?

    /// Creates one finding.
    public init(check: String, severity: Severity, message: String, path: String? = nil, hint: String? = nil) {
        self.check = check
        self.severity = severity
        self.message = message
        self.path = path
        self.hint = hint
    }
}

/// The structured result of `gnostic doctor`.
public struct DoctorReport: Codable, Sendable, Equatable {
    /// Whether every check passed. Warnings do not make a Node unhealthy.
    public let healthy: Bool
    /// Whether the online checks ran.
    public let online: Bool
    /// The manifest file the report describes.
    public let manifestPath: String
    /// Every finding, in check order.
    public let findings: [DoctorFinding]

    /// The count of findings at one severity.
    ///
    /// - Parameter severity: The severity to count.
    /// - Returns: The number of matching findings.
    public func count(_ severity: DoctorFinding.Severity) -> Int {
        findings.filter { $0.severity == severity }.count
    }
}

/// The environment probes `doctor` needs, so its checks stay testable.
public protocol DoctorProbing: Sendable {
    /// Whether a filesystem path exists.
    ///
    /// - Parameter path: The path to test.
    /// - Returns: `true` when the path exists.
    func fileExists(atPath path: String) -> Bool
    /// Whether a TCP connection to a host and port succeeds within a timeout.
    ///
    /// - Parameters:
    ///   - host: The host name or address.
    ///   - port: The TCP port.
    ///   - timeout: The maximum time to wait, in seconds.
    /// - Returns: `true` when the connection succeeds.
    func tcpReachable(host: String, port: Int, timeout: Double) -> Bool
}

/// The default probes, backed by `FileManager` and POSIX sockets.
public struct SystemDoctorProbe: DoctorProbing {
    /// Creates the system probe.
    public init() {}

    /// Whether a filesystem path exists.
    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Whether a TCP connection succeeds within a timeout.
    public func tcpReachable(host: String, port: Int, timeout: Double) -> Bool {
        POSIXTCPProbe.connect(host: host, port: port, timeout: timeout)
    }
}

/// Options for one `doctor` run.
public struct DoctorOptions: Sendable, Equatable {
    /// Whether the online checks run.
    public var online: Bool
    /// Whether the provider endpoint is also probed. Implies online.
    public var checkProvider: Bool

    /// Creates one options value.
    ///
    /// - Parameters:
    ///   - online: Whether the online checks run.
    ///   - checkProvider: Whether the provider endpoint is probed.
    public init(online: Bool = false, checkProvider: Bool = false) {
        self.online = online
        self.checkProvider = checkProvider
    }

    /// The default, fully offline options.
    public static let offline = DoctorOptions()
}

/// The offline and opt-in online checks behind `gnostic doctor`.
public enum DoctorLogic {
    /// The protocol major this build expects. A mismatch with the compiled
    /// constant indicates a partially linked or stale runtime.
    public static let expectedProtocolMajor = GnosticProtocol.currentMajor

    /// Runs every check and returns a structured report.
    ///
    /// - Parameters:
    ///   - store: The manifest store.
    ///   - composition: The compiled composition source.
    ///   - registry: The module registry, or `nil` when it cannot be read.
    ///   - options: The check options.
    ///   - probe: The environment probes.
    /// - Returns: The report. `healthy` is false when any finding is an error.
    public static func run(
        store: CLIConfigurationStore,
        composition: BackendComposition = .default,
        registry: ModuleRegistry? = nil,
        options: DoctorOptions = .offline,
        probe: some DoctorProbing = SystemDoctorProbe()
    ) -> DoctorReport {
        let manifestPath = store.path().path
        var findings: [DoctorFinding] = []
        let validation = ConfigConsoleLogic.validationReport(store: store)
        if !validation.valid {
            for issue in validation.issues {
                findings.append(
                    DoctorFinding(
                        check: "manifest",
                        severity: .error,
                        message: issue.message,
                        path: issue.path,
                        hint: issue.hint
                    )
                )
            }
            return report(findings: findings, manifestPath: manifestPath, online: false)
        }
        findings.append(DoctorFinding(check: "manifest", severity: .ok, message: "Configuration is valid.", path: manifestPath))

        guard let manifest = try? store.loadManifest() else {
            findings.append(DoctorFinding(check: "manifest", severity: .error, message: "The manifest could not be read after validation.", path: manifestPath))
            return report(findings: findings, manifestPath: manifestPath, online: false)
        }

        findings.append(contentsOf: workspaceFindings(manifest: manifest, probe: probe))
        for ascendant in manifest.ascendants {
            findings.append(contentsOf: ascendantFindings(ascendant: ascendant, composition: composition, registry: registry, probe: probe))
        }

        var checkedOnline = false
        if options.online || options.checkProvider {
            checkedOnline = true
            findings.append(contentsOf: onlineFindings(manifest: manifest, composition: composition, options: options, probe: probe))
        }
        return report(findings: findings, manifestPath: manifestPath, online: checkedOnline)
    }

    private static func report(findings: [DoctorFinding], manifestPath: String, online: Bool) -> DoctorReport {
        DoctorReport(
            healthy: !findings.contains { $0.severity == .error },
            online: online,
            manifestPath: manifestPath,
            findings: findings
        )
    }

    private static func workspaceFindings(manifest: NodeManifest, probe: some DoctorProbing) -> [DoctorFinding] {
        manifest.workspaces.compactMap { workspace in
            guard let path = localPath(for: workspace.uri) else { return nil }
            guard !probe.fileExists(atPath: path) else {
                return DoctorFinding(
                    check: "workspace",
                    severity: .ok,
                    message: "Workspace '\(workspace.name)' path exists.",
                    path: path
                )
            }
            return DoctorFinding(
                check: "workspace",
                severity: .warning,
                message: "Workspace '\(workspace.name)' path does not exist.",
                path: path,
                hint: "Create the directory or update the Workspace URI with `config workspace update`."
            )
        }
    }

    private static func localPath(for uri: String) -> String? {
        if uri.hasPrefix("file://") {
            return URL(string: uri)?.path
        }
        guard !uri.contains("://") else { return nil }
        return uri.hasPrefix("/") || uri.hasPrefix("~") ? (uri as NSString).expandingTildeInPath : nil
    }

    private static func ascendantFindings(
        ascendant: NodeManifest.Ascendant,
        composition: BackendComposition,
        registry: ModuleRegistry?,
        probe: some DoctorProbing
    ) -> [DoctorFinding] {
        let id = ascendant.id.uuidString.lowercased()
        let backendPath = "ascendants[\(id)].backend"
        var findings: [DoctorFinding] = []
        let configuration = PositronicBackendConfiguration(backend: ascendant.backend)

        guard let schema = composition.settingsSchema(for: ascendant.backend.kind) else {
            findings.append(
                DoctorFinding(
                    check: "backend",
                    severity: .error,
                    message: "Backend kind '\(ascendant.backend.kind)' is not registered in this build.",
                    path: "\(backendPath).kind",
                    hint: "Rebuild with the backend's target linked, or change the kind."
                )
            )
            return findings
        }

        let provider = configuration.provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if provider.isEmpty {
            findings.append(
                DoctorFinding(
                    check: "provider",
                    severity: .error,
                    message: "Ascendant '\(ascendant.name)' has no provider configured.",
                    path: "\(backendPath).settings.provider",
                    hint: "Run `config backend set \(id) provider <name>`."
                )
            )
        } else {
            findings.append(DoctorFinding(check: "provider", severity: .ok, message: "Ascendant '\(ascendant.name)' provider is '\(provider)'.", path: "\(backendPath).settings.provider"))
        }

        for tier in ["model", "utilityModel", "fastModel"] {
            guard let tierValue = ascendant.backend.settings[tier] else { continue }
            let value = tierValue.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                findings.append(
                    DoctorFinding(
                        check: "modelTier",
                        severity: .error,
                        message: "Model tier '\(tier)' is set but empty on Ascendant '\(ascendant.name)'.",
                        path: "\(backendPath).settings.\(tier)",
                        hint: "Set a model name with `config backend set \(id) \(tier) <model>`, or clear the key."
                    )
                )
            } else {
                findings.append(DoctorFinding(check: "modelTier", severity: .ok, message: "Model tier '\(tier)' is '\(value)'.", path: "\(backendPath).settings.\(tier)"))
            }
        }

        let selectedModules = ConfigConsoleLogic.selectedNames(in: ascendant.backend)
        let requiresModelService = selectedModules.contains { composition.moduleDescriptor(named: $0)?.requiresModelService == true }
        if requiresModelService, provider.isEmpty {
            findings.append(
                DoctorFinding(
                    check: "modelService",
                    severity: .error,
                    message: "Ascendant '\(ascendant.name)' selects a module that needs a model service, but no provider is configured.",
                    path: "\(backendPath).settings.provider",
                    hint: "Configure a provider before starting the Node."
                )
            )
        }

        for secretName in schema.secretNames {
            let set = ascendant.backend.secrets[secretName]?.stringValue.map { !$0.isEmpty } ?? false
            if !set, requiresModelService {
                findings.append(
                    DoctorFinding(
                        check: "secret",
                        severity: .error,
                        message: "Secret '\(secretName)' is not set on Ascendant '\(ascendant.name)'.",
                        path: "\(backendPath).secrets.\(secretName)",
                        hint: "Run `config backend set-secret \(id) \(secretName)` and paste the value."
                    )
                )
            } else if !set {
                findings.append(
                    DoctorFinding(
                        check: "secret",
                        severity: .warning,
                        message: "Secret '\(secretName)' is not set on Ascendant '\(ascendant.name)'.",
                        path: "\(backendPath).secrets.\(secretName)",
                        hint: "Set it only when the provider needs it."
                    )
                )
            }
        }

        for moduleName in selectedModules {
            guard let module = composition.moduleDescriptor(named: moduleName) else {
                findings.append(
                    DoctorFinding(
                        check: "module",
                        severity: .error,
                        message: "Ascendant '\(ascendant.name)' selects module '\(moduleName)', which is not compiled into this build.",
                        path: "\(backendPath).settings.extensions",
                        hint: "Rebuild with the module linked, or disable it with `config module disable \(id) \(moduleName)`."
                    )
                )
                continue
            }
            findings.append(DoctorFinding(check: "module", severity: .ok, message: "Module '\(moduleName)' is compiled in.", path: "\(backendPath).settings.extensions"))
            findings.append(contentsOf: registryFindings(module: module, registry: registry, id: id, backendPath: backendPath))
            let localSettings = moduleLocalSettings(moduleName: moduleName, backend: ascendant.backend)
            for prerequisite in module.prerequisites?(localSettings) ?? [] {
                let severity: DoctorFinding.Severity = prerequisite.isAvailable ? .ok : .error
                findings.append(
                    DoctorFinding(
                        check: "executor",
                        severity: severity,
                        message: prerequisite.isAvailable
                            ? "Module '\(moduleName)' prerequisite '\(prerequisite.name)' is available."
                            : "Module '\(moduleName)' prerequisite '\(prerequisite.name)' is missing.",
                        path: prerequisite.path,
                        hint: prerequisite.isAvailable ? nil : prerequisite.hint
                    )
                )
            }
        }
        return findings
    }

    private static func registryFindings(
        module: GnosticModule,
        registry: ModuleRegistry?,
        id: String,
        backendPath: String
    ) -> [DoctorFinding] {
        guard let registryID = module.registryID else { return [] }
        guard let entry = registry?.entry(id: registryID) else {
            guard registry != nil else { return [] }
            return [
                DoctorFinding(
                    check: "registry",
                    severity: .error,
                    message: "Module '\(module.name)' names registry id '\(registryID)', which is absent from experiments.json.",
                    path: "\(backendPath).settings.extensions",
                    hint: "Add the entry or remove the descriptor's registry id."
                )
            ]
        }
        if entry.isCautionary {
            return [
                DoctorFinding(
                    check: "registry",
                    severity: .warning,
                    message: "Module '\(module.name)' is \(entry.status) in experiments.json.",
                    path: "\(backendPath).settings.extensions",
                    hint: "Promote the module or accept the risk in the owning issue \(entry.owningIssue)."
                )
            ]
        }
        return [DoctorFinding(check: "registry", severity: .ok, message: "Module '\(module.name)' registry status is '\(entry.status)'.", path: "\(backendPath).settings.extensions")]
    }

    static func moduleLocalSettings(moduleName: String, backend: NodeManifest.BackendConfiguration) -> [String: String] {
        let prefix = "\(moduleName)."
        var result: [String: String] = [:]
        for (key, value) in backend.settings where key.hasPrefix(prefix) {
            if let string = value.stringValue {
                result[String(key.dropFirst(prefix.count))] = string
            }
        }
        return result
    }

    private static func onlineFindings(
        manifest: NodeManifest,
        composition: BackendComposition,
        options: DoctorOptions,
        probe: some DoctorProbing
    ) -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        let reachable = probe.tcpReachable(host: manifest.broker.host, port: manifest.broker.port, timeout: 2)
        findings.append(
            DoctorFinding(
                check: "broker",
                severity: reachable ? .ok : .error,
                message: reachable
                    ? "Broker at \(manifest.broker.host):\(manifest.broker.port) is reachable."
                    : "Broker at \(manifest.broker.host):\(manifest.broker.port) is unreachable.",
                path: "broker",
                hint: reachable ? nil : "Start the broker, or correct `broker.host` and `broker.port`."
            )
        )
        if GnosticProtocol.currentMajor == expectedProtocolMajor {
            findings.append(DoctorFinding(check: "protocolMajor", severity: .ok, message: "Protocol major \(GnosticProtocol.currentMajor) is compatible."))
        } else {
            findings.append(
                DoctorFinding(
                    check: "protocolMajor",
                    severity: .error,
                    message: "Protocol major \(GnosticProtocol.currentMajor) does not match the expected \(expectedProtocolMajor).",
                    hint: "Rebuild the CLI and the Node from the same revision."
                )
            )
        }
        if options.checkProvider {
            let endpoints = manifest.ascendants.compactMap { PositronicBackendConfiguration(backend: $0.backend).endpoint }
            for endpoint in endpoints {
                guard let url = URL(string: endpoint), let host = url.host else { continue }
                let port = url.port ?? (url.scheme == "http" ? 80 : 443)
                let up = probe.tcpReachable(host: host, port: port, timeout: 3)
                findings.append(
                    DoctorFinding(
                        check: "provider",
                        severity: up ? .ok : .warning,
                        message: up ? "Provider endpoint \(endpoint) is reachable." : "Provider endpoint \(endpoint) is unreachable.",
                        hint: up ? nil : "Check the endpoint, network access, and provider status."
                    )
                )
            }
        }
        return findings
    }
}

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A minimal non-blocking TCP connect used for the opt-in online checks.
enum POSIXTCPProbe {
    static func connect(host: String, port: Int, timeout: Double) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let result else { return false }
        defer { freeaddrinfo(result) }
        var pointer: UnsafeMutablePointer<addrinfo>? = result
        while let current = pointer {
            let descriptor = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if descriptor >= 0 {
                let flags = fcntl(descriptor, F_GETFL, 0)
                _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
                if systemConnect(descriptor, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 {
                    close(descriptor)
                    return true
                }
                if errno == EINPROGRESS {
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&pollDescriptor, 1, Int32(timeout * 1_000))
                    if ready > 0, pollDescriptor.revents & Int16(POLLOUT) != 0 {
                        close(descriptor)
                        return true
                    }
                }
                close(descriptor)
            }
            pointer = current.pointee.ai_next
        }
        return false
    }

    private static func systemConnect(_ descriptor: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
        #if canImport(Glibc)
        return Glibc.connect(descriptor, address, length)
        #else
        return Darwin.connect(descriptor, address, length)
        #endif
    }
}
