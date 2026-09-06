#if AUDIOORBIT_E2E
import AppKit
import Darwin
import Foundation

/// Compiled only by scripts/test-e2e.sh. Atomic snapshots avoid a control
/// server in the app; the run directory is private to the current user.
@MainActor
final class E2EObservation {
    struct Manifest: Decodable {
        let runID: String
        let runnerPID: Int32
    }

    let directory: URL
    let manifest: Manifest
    let preferences: UserDefaults
    private let preferencesSuite: String
    private var task: Task<Void, Never>?
    private var terminationSource: DispatchSourceSignal?
    private let instanceID = UUID().uuidString

    static func fromArguments() -> E2EObservation? {
        guard let index = CommandLine.arguments.firstIndex(of: "--e2e-directory") else { return nil }
        guard CommandLine.arguments.indices.contains(index + 1) else {
            fatalError("Missing E2E run directory")
        }
        do { return try E2EObservation(path: CommandLine.arguments[index + 1]) }
        catch { fatalError("Invalid E2E run: \(error)") }
    }

    private init(path: String) throws {
        directory = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
            throw NSError(domain: "E2EPrivateDirectory", code: 1)
        }
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf:
            directory.appendingPathComponent("manifest.json")))
        guard UUID(uuidString: manifest.runID) != nil, manifest.runnerPID > 1,
              kill(manifest.runnerPID, 0) == 0 else {
            throw NSError(domain: "E2EManifest", code: 1)
        }
        try Data(String(getpid()).utf8).write(to: directory.appendingPathComponent("app.pid"), options: .atomic)
        preferencesSuite = "me.snowzjx.AudioOrbit.E2E.\(manifest.runID)"
        preferences = UserDefaults(suiteName: preferencesSuite)!
        preferences.register(defaults: ["AudioOrbitHasCompletedOnboarding": true,
                                       "AudioOrbitFollowNotificationsEnabled": false])
    }

    func stop() {
        task?.cancel()
        terminationSource?.cancel()
        preferences.removePersistentDomain(forName: preferencesSuite)
    }

    func start(model: AppModel) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { Task { await model.quit() } }
        source.resume()
        terminationSource = source
        task = Task { [weak self, weak model] in
            var sequence = 0
            while !Task.isCancelled, let self, let model {
                if kill(self.manifest.runnerPID, 0) != 0 || FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("stop.request").path) {
                    await model.quit()
                    return
                }
                sequence += 1
                var snapshot = model.e2eSnapshot()
                snapshot["schema"] = 1
                snapshot["runID"] = self.manifest.runID
                snapshot["instanceID"] = self.instanceID
                snapshot["sequence"] = sequence
                snapshot["uptime"] = ProcessInfo.processInfo.systemUptime
                do {
                    let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
                    try data.write(to: self.directory.appendingPathComponent("snapshot.json"), options: .atomic)
                } catch {
                    // A broken observation channel must never leave test taps running.
                    await model.quit()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
#endif
