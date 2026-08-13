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
            allowsSystemWebKitClientAssociation: isSystemWebKitMediaHelper(audioProcess)
        )
    }

    private func isSystemWebKitMediaHelper(_ audioProcess: AudioProcessSnapshot) -> Bool {
        guard audioProcess.bundleIdentifier == "com.apple.WebKit.GPU",
              let executableURL = NSRunningApplication(
                  processIdentifier: audioProcess.pid
              )?.executableURL else {
            return false
        }
        let path = executableURL.standardizedFileURL.path
        return path.contains("/System/Library/Frameworks/WebKit.framework/")
            && path.hasSuffix("/com.apple.WebKit.GPU")
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
