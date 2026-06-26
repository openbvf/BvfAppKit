import Darwin

/// Sets the core dump size limit to zero to prevent decrypted plaintext from being written to a crash dump.
public enum DisableCoreDumps {
    /// Apply the rlimit. Call once at app startup, before any sensitive data is loaded into memory.
    public static func apply() {
        var rl = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &rl)
    }
}
