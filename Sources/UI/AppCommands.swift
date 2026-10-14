import Foundation

public enum AppCommand {
    /// `userInfo` key of `undo` naming the database whose step to undo ("" for the main one).
    public static let databaseKey = "database"
    public static let openVault = Notification.Name("KeeMac.Command.OpenVault")
    public static let newVault = Notification.Name("KeeMac.Command.NewVault")
    public static let selectKeyFile = Notification.Name("KeeMac.Command.SelectKeyFile")
    public static let clearKeyFile = Notification.Name("KeeMac.Command.ClearKeyFile")
    public static let lockVault = Notification.Name("KeeMac.Command.LockVault")
    public static let openPasswordHealth = Notification.Name("KeeMac.Command.OpenPasswordHealth")
    public static let mergeDatabase = Notification.Name("KeeMac.Command.MergeDatabase")
    public static let openDatabaseSettings = Notification.Name("KeeMac.Command.OpenDatabaseSettings")
    public static let importData = Notification.Name("KeeMac.Command.Import")
    public static let exportData = Notification.Name("KeeMac.Command.Export")
    public static let undo = Notification.Name("KeeMac.Command.Undo")
    public static let redo = Notification.Name("KeeMac.Command.Redo")
    public static let showMainWindow = Notification.Name("KeeMac.Command.ShowMainWindow")
    public static let addAdditionalDatabase = Notification.Name("KeeMac.Command.AddAdditionalDatabase")
    /// Posted when a database is unlocked or locked; `vaultUnlockedUserInfoKey` holds the new state.
    public static let vaultLockStateChanged = Notification.Name("KeeMac.Command.VaultLockStateChanged")
    public static let vaultUnlockedUserInfoKey = "unlocked"
    public static let dockIconVisibilityChanged = Notification.Name("KeeMac.Command.DockIconVisibilityChanged")
    public static let dockIconVisibilityUserInfoKey = "showDockIcon"
}
