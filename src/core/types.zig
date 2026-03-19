//! Core enum vocabulary for the live TOM.

/// Lifecycle state for documents and nodes.
pub const LifecycleState = enum {
    /// Connected to an active backend or otherwise expected to keep changing.
    live,
    /// Inspectable but not directly editable through the current surface.
    read_only,
    /// Explicitly captured or otherwise no longer expected to mutate.
    frozen,
    /// Not currently live, but still treated as a recoverable source-backed
    /// object rather than as a final artifact.
    detached,
};

/// Structural node kinds in the TOM.
pub const NodeKind = enum {
    /// Root document node for one daemon-owned TOM.
    document,
    /// Nested document or stage boundary.
    subdocument,
    /// Generic structural container.
    container,
    /// Explicit horizontal split container.
    h_container,
    /// Explicit vertical split container.
    v_container,
    /// Scroll-bearing structural region.
    scroll_region,
    /// Appendable non-terminal text or message leaf.
    text_leaf,
    /// Live terminal-backed leaf.
    tty_leaf,
    /// File-backed leaf that is monitored for updates.
    monitored_file_leaf,
    /// File-backed leaf with static content.
    static_file_leaf,
    /// Monitor-style synthetic leaf.
    monitor_leaf,
    /// Modeline or status-strip region.
    modeline_region,
    /// Menu region or menu projection target.
    menu_region,
};

/// Viewer-local interaction mode.
pub const ViewerMode = enum {
    /// Bias toward staying pinned to the tail of append-oriented content.
    follow_tail,
    /// Bias toward manual inspection rather than automatic tail following.
    inspect,
};
