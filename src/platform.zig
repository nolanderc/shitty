pub const x11 = @import("platform/x11.zig");

pub const Modifiers = packed struct(u3) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
};

pub const Key = enum {
    @"0",
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",

    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,

    @"!",
    @"@",
    @"#",
    @"$",
    @"%",
    @"^",
    @"&",
    @"*",
    @"(",
    @")",
    @"{",
    @"}",
    @"[",
    @"]",
    @"=",
    @"-",
    @"+",
    @"/",
    @"\\",
    @",",
    @".",
    @"<",
    @">",
    @":",
    @";",
    @"'",
    @"_",
    @"~",
    @"\"",

    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,

    tab,
    space,
    enter,
    escape,
    backspace,
    delete,
};
