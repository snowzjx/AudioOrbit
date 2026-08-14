import Foundation

struct OnboardingStateStore {
    private static let completionKey = "AudioOrbitHasCompletedOnboarding"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isCompleted: Bool {
        defaults.bool(forKey: Self.completionKey)
    }

    func setCompleted(_ completed: Bool) {
        defaults.set(completed, forKey: Self.completionKey)
    }
}
