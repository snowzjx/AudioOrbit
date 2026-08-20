import AppKit
import Darwin
import Foundation

/// Resolves the visible application that owns a producing audio
/// process. The resolution runs once per playing source per observation
/// tick, and enumerating every running application with LaunchServices
/// lookups on every call dominated playback CPU (measured ~15-25%).
/// The application table changes rarely, so it is cached for a short TTL.
///
/// The first enumeration is expensive (hundreds of localizedName lookups)
/// and used to block the launch-time evidence path for seconds. The cache
/// is therefore warmed on a background queue at startup; while it is cold,
/// resolve falls back to a fast enumeration with bundle-derived names so
/// the main thread never waits on LaunchServices.
final class ProcessWindowAssociationResolver {
    /// How long the cached application table may be reused. App launches
    /// and quits are rare; a fresh association can afford this delay.
    private static let applicationsCacheTTL: Duration = .seconds(2)

    private let lock = NSLock()
    private var cachedApplications: [WindowOwnerSnapshot]?
    private var cachedAt: ContinuousClock.Instant?
    private var isWarming = false

    /// Pre-populates the cache off the calling thread so the first
    /// resolve during launch does not stall on LaunchServices lookups.
    func warmApplicationsCache() {
        lock.lock()
        if cachedApplications != nil || isWarming {
            lock.unlock()
            return
        }
        isWarming = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let applications = self.enumerateApplications(withLocalizedNames: true)
            self.lock.lock()
            self.cachedApplications = applications
            self.cachedAt = ContinuousClock.now
            self.isWarming = false
            self.lock.unlock()
        }
    }

    func resolve(_ audioProcess: AudioProcessSnapshot) -> ProcessWindowAssociation? {
        ProcessWindowAssociationPolicy.resolve(
            audioProcess: audioProcess,
            applications: snapshotApplications(),
            parentPID: parentPID(of:),
            allowsSystemWebKitClientAssociation:
                isSystemWebKitHelper(audioProcess)
        )
    }

    private func snapshotApplications() -> [WindowOwnerSnapshot] {
        lock.lock()
        let now = ContinuousClock.now
        if let cachedApplications,
           let cachedAt,
           now - cachedAt < Self.applicationsCacheTTL {
            lock.unlock()
            return cachedApplications
        }
        let cold = cachedApplications == nil
        lock.unlock()

        if cold {
            // Fast synchronous fallback with bundle-derived names; the
            // background warm-up replaces it with localized names shortly.
            warmApplicationsCache()
            return enumerateApplications(withLocalizedNames: false)
        }

        let applications = enumerateApplications(withLocalizedNames: true)
        lock.lock()
        cachedApplications = applications
        cachedAt = ContinuousClock.now
        lock.unlock()
        return applications
    }

    private func enumerateApplications(
        withLocalizedNames: Bool
    ) -> [WindowOwnerSnapshot] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated else { return nil }
            let isRegular = application.activationPolicy == .regular
            let fallbackName = application.bundleIdentifier?
                .split(separator: ".").last.map(String.init)
            // Only regular applications can become window owners, so only
            // they need the (expensive) localized name; background and
            // system processes keep the cheap bundle-derived name. This
            // keeps the warm-up enumeration a fraction of its former cost.
            let name: String
            if withLocalizedNames, isRegular {
                name = application.localizedName
                    ?? fallbackName
                    ?? "Application \(application.processIdentifier)"
            } else {
                name = fallbackName
                    ?? "Application \(application.processIdentifier)"
            }
            return WindowOwnerSnapshot(
                pid: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                name: name,
                isRegularApplication: isRegular
            )
        }
    }

    /// Both the GPU media helper and the per-tab WebContent renderers can
    /// produce Safari audio (the latter hosts WebRTC and WebAudio media).
    /// Either is a valid client for the name-prefix association, which
    /// remains conservative: only the longest unique regular-app prefix is
    /// accepted. The running-app lookup can fail transiently while Safari
    /// restarts helpers, so proc_pidpath provides a second path lookup; a
    /// bundle identifier alone is never treated as proof of a system helper.
    private func isSystemWebKitHelper(_ audioProcess: AudioProcessSnapshot) -> Bool {
        guard audioProcess.bundleIdentifier == "com.apple.WebKit.GPU"
                || audioProcess.bundleIdentifier == "com.apple.WebKit.WebContent"
        else { return false }
        let path = NSRunningApplication(processIdentifier: audioProcess.pid)?
            .executableURL?.standardizedFileURL.path
            ?? executablePath(for: audioProcess.pid)
        guard let path else { return false }
        return path.contains("/System/Library/Frameworks/WebKit.framework/")
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](
            repeating: 0,
            // proc_pidpath requires up to 4 * MAXPATHLEN bytes; the SDK macro
            // is not imported into Swift.
            count: 4_096
        )
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let byteCount = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard byteCount == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
