pub const LifecycleState = enum {
    live,
    read_only,
    frozen,
    detached,
};

pub const NodeKind = enum {
    document,
    subdocument,
    container,
    scroll_region,
    tty_leaf,
    monitored_file_leaf,
    static_file_leaf,
    monitor_leaf,
    modeline_region,
    menu_region,
};

pub const ViewerMode = enum {
    follow_tail,
    inspect,
};
