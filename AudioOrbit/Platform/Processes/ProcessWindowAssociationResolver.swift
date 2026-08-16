import AppKit
import Darwin
import Foundation

struct ProcessWindowAssociationResolver {
    func resolve(_ audioProcess: AudioProcessSnapshot) -> ProcessWindowAssociation? {
        ProcessWindowAssociationPolicy.resolve(
            audioProcess: audioProcess,
            applications: NSWorkspace.shared.runningApplications.compactMap { application in
                guard !application.isTerminated else { return nil }
                return WindowOwnerSnapshot(
                    pid: application.processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    name: application.localizedName
                        ?? application.bundleIdentifier?.split(separator: ".").last.map(String.init)
                        ?? "Application \(application.processIdentifier)",
                    isRegularApplication: application.activationPolicy == .regular
                )
            },
            parentPID: parentPID(of:),
            allowsSystemWebKitClientAssociation:
                isSystemWebKitHelper(audioProcess)
        )
    }

    /// Both the GPU media helper and the per-tab WebContent renderers can
    /// produce Safari audio (the latter hosts WebRTC and WebAudio media).
    /// Either is a valid client for the name-prefix association, which
    /// remains conservative: only the longest unique regular-app prefix is
    /// accepted. The running-app lookup can fail transiently while Safari
    /// restarts helpers; the Apple-signed bundle identifier alone is then
    /// enough to trust the process.
    private func isSystemWebKitHelper(_ audioProcess: AudioProcessSnapshot) -> Bool {
        guard audioProcess.bundleIdentifier == "com.apple.WebKit.GPU"
                || audioProcess.bundleIdentifier == "com.apple.WebKit.WebContent"
        else { return false }
        guard let executableURL = NSRunningApplication(
            processIdentifier: audioProcess.pid
        )?.executableURL else {
            return true
        }
        let path = executableURL.standardizedFileURL.path
        return path.contains("/System/Library/Frameworks/WebKit.framework/")
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
