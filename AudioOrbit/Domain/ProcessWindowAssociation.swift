import Foundation

struct WindowOwnerSnapshot: Equatable, Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
    let isRegularApplication: Bool
}

enum ProcessWindowAssociationReason: String, Equatable, Sendable {
    case sameProcess = "same process"
    case parentApplication = "parent application"
    case matchingBundle = "matching application bundle"
    case systemWebKitClient = "system WebKit media helper"
}

struct ProcessWindowAssociation: Equatable, Sendable {
    let audioProcess: AudioProcessSnapshot
    let windowOwner: WindowOwnerSnapshot
    let reason: ProcessWindowAssociationReason
}

enum ProcessWindowAssociationPolicy {
    static let maximumParentDepth = 8

    static func resolve(
        audioProcess: AudioProcessSnapshot,
        applications: [WindowOwnerSnapshot],
        parentPID: (pid_t) -> pid_t?,
        allowsSystemWebKitClientAssociation: Bool = false
    ) -> ProcessWindowAssociation? {
        if let sameProcess = applications.first(where: {
            $0.pid == audioProcess.pid && $0.isRegularApplication
        }) {
            return ProcessWindowAssociation(
                audioProcess: audioProcess,
                windowOwner: sameProcess,
                reason: .sameProcess
            )
        }

        let applicationsByPID = Dictionary(uniqueKeysWithValues: applications.map { ($0.pid, $0) })
        var visited: Set<pid_t> = [audioProcess.pid]
        var currentPID = audioProcess.pid
        for _ in 0..<maximumParentDepth {
            guard let parent = parentPID(currentPID), parent > 1, visited.insert(parent).inserted else {
                break
            }
            if let owner = applicationsByPID[parent], owner.isRegularApplication {
                return ProcessWindowAssociation(
                    audioProcess: audioProcess,
                    windowOwner: owner,
                    reason: .parentApplication
                )
            }
            currentPID = parent
        }

        if let bundleIdentifier = audioProcess.bundleIdentifier {
            let bundleMatches = applications.filter {
                $0.isRegularApplication && $0.bundleIdentifier == bundleIdentifier
            }
            if bundleMatches.count == 1, let owner = bundleMatches.first {
                return ProcessWindowAssociation(
                    audioProcess: audioProcess,
                    windowOwner: owner,
                    reason: .matchingBundle
                )
            }
        }

        // WebKit GPU services are launchd-owned on current macOS releases, so
        // neither their parent PID nor their bundle identifier identifies the
        // client application. LaunchServices does, however, expose a localized
        // client-qualified name such as "Safari Graphics and Media". The
        // platform resolver enables this path only after verifying that the
        // source is the system WebKit GPU service.
        if allowsSystemWebKitClientAssociation,
           let owner = longestUniqueApplicationNamePrefix(
               of: audioProcess.name,
               applications: applications
           ) {
            return ProcessWindowAssociation(
                audioProcess: audioProcess,
                windowOwner: owner,
                reason: .systemWebKitClient
            )
        }

        return nil
    }

    private static func longestUniqueApplicationNamePrefix(
        of helperName: String,
        applications: [WindowOwnerSnapshot]
    ) -> WindowOwnerSnapshot? {
        let matches = applications.filter {
            $0.isRegularApplication
                && helperName.count > $0.name.count
                && helperName.hasPrefix($0.name)
        }
        guard let longestLength = matches.map(\.name.count).max() else { return nil }
        let longestMatches = matches.filter { $0.name.count == longestLength }
        guard longestMatches.count == 1 else { return nil }
        return longestMatches[0]
    }
}
