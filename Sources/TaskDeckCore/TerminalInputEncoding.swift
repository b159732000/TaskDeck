/// Application-level terminal input mappings that must remain stable across
/// renderer and transport changes.
public enum TerminalInputEncoding {
    /// Claude Code's own terminal setup maps Shift+Enter to Meta+Return for
    /// terminals without a native enhanced-keyboard identity. LF used to work
    /// as Ctrl+J, but newer input layers can treat it as submit just like CR.
    public static func multilineShiftReturn(
        keyCode: UInt16,
        shift: Bool,
        command: Bool,
        option: Bool,
        control: Bool
    ) -> [UInt8]? {
        guard (keyCode == 36 || keyCode == 76),
              shift, !command, !option, !control else { return nil }
        return [0x1b, 0x0d]
    }
}
