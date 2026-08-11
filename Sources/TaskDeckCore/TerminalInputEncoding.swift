/// Application-level terminal input mappings that must remain stable across
/// renderer and transport changes.
public enum TerminalInputEncoding {
    /// Shift+Return → LF, the byte Ctrl+J produces.
    ///
    /// Read out of the Claude Code 2.1.227 binary rather than inferred: its key
    /// parser names a lone `\n` "enter", and the prompt inserts a newline for
    /// "enter" as well as for a "return" that carries shift or meta. LF,
    /// ESC+CR (`\x1b\r`, what `/terminal-setup` installs for VS Code) and the
    /// kitty `CSI 13;2u` therefore all insert a newline — the byte was never
    /// what broke Shift+Enter. LF is kept because it is one byte, needs no
    /// enhanced-keyboard negotiation, and carries no ESC prefix that a
    /// tokenizer could split into a separate Escape key.
    ///
    /// The mapping is only half the story: see
    /// `GlassTerminalView.installShiftReturnMonitor` for why it has to be
    /// dispatched from a local key-down monitor.
    public static func multilineShiftReturn(
        keyCode: UInt16,
        shift: Bool,
        command: Bool,
        option: Bool,
        control: Bool
    ) -> [UInt8]? {
        guard (keyCode == 36 || keyCode == 76),
              shift, !command, !option, !control else { return nil }
        return [0x0a]
    }
}
