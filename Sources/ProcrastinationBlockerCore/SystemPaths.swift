public enum SystemPaths {
    public static let launchDaemonLabel = "com.rieg.procrastination-blocker.enforcer"
    public static let rootStateDirectory = "/Library/Application Support/ProcrastinationBlocker"
    public static let sessionStatePath = "\(rootStateDirectory)/session.json"
    public static let stagedSessionStatePath = "\(rootStateDirectory)/session.pending.json"
    public static let enforcementLockPath = "\(rootStateDirectory)/enforcement.lock"
    public static let helperPath = "/Library/PrivilegedHelperTools/\(launchDaemonLabel)"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(launchDaemonLabel).plist"
    public static let hostsPath = "/etc/hosts"
    public static let managedBlockStartMarker = "# >>> procrastination blocker >>>"
    public static let managedBlockEndMarker = "# <<< procrastination blocker <<<"
}
