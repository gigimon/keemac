import Foundation

public enum AppCommand {
    public static let openVault = Notification.Name("KeeMac.Command.OpenVault")
    public static let selectKeyFile = Notification.Name("KeeMac.Command.SelectKeyFile")
    public static let clearKeyFile = Notification.Name("KeeMac.Command.ClearKeyFile")
    public static let lockVault = Notification.Name("KeeMac.Command.LockVault")
    public static let dockIconVisibilityChanged = Notification.Name("KeeMac.Command.DockIconVisibilityChanged")
    public static let dockIconVisibilityUserInfoKey = "showDockIcon"
}
