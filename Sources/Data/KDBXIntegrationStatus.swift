public enum KDBXIntegrationStatus: String, Sendable {
    case pending
    case available
    case blocked

    public static let current: KDBXIntegrationStatus = .available
    public static let backend: String = "KeePassKit"
}
