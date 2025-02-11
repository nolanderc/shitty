const std = @import("std");
const c = @import("c").includes;
const unix = @cImport({
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("pwd.h");
});

pub const WindowSize = extern struct {
    rows: u16,
    cols: u16,
    pixels_x: u16,
    pixels_y: u16,
};

pub fn open(size: WindowSize) !Terminal {
    var master: std.fs.File = undefined;
    var child: std.fs.File = undefined;

    const winsize = unix.struct_winsize{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = size.pixels_x,
        .ws_ypixel = size.pixels_y,
    };

    const result = unix.openpty(&master.handle, &child.handle, null, null, &winsize);
    if (result < 0) return error.NotFound;

    return .{ .master = master, .child = child };
}

pub const Terminal = struct {
    master: std.fs.File,
    child: std.fs.File,

    pub fn deinit(term: Terminal) void {
        term.master.close();
        term.child.close();
    }

    pub fn exec(term: *Terminal) !Shell {
        const pid = try std.posix.fork();

        if (pid != 0) {
            // parent
            term.child.close();
            term.child.handle = 0;
            return .{ .io = term.master, .child_pid = pid };
        }

        // child
        term.master.close();
        const child = term.child;

        errdefer |err| {
            std.log.err("could exec child process: {} ({})", .{
                err,
                std.posix.errno(-1),
            });
            std.c.exit(1);
        }

        if (unix.setsid() == -1) {
            return error.SetSid;
        }

        if (unix.ioctl(child.handle, unix.TIOCSCTTY, @as(c_int, 0)) == -1) {
            return error.SetControllingTerminal;
        }

        try std.posix.dup2(child.handle, std.posix.STDIN_FILENO);
        try std.posix.dup2(child.handle, std.posix.STDOUT_FILENO);
        try std.posix.dup2(child.handle, std.posix.STDERR_FILENO);
        if (child.handle > std.posix.STDERR_FILENO) child.close();

        const shell = getShellPath();
        const err = std.posix.execvpeZ(shell, &.{ shell, null }, std.c.environ);

        std.log.err("could not exec shell: {}", .{err});

        std.c.exit(1);
    }
};

fn getShellPath() [:0]const u8 {
    if (std.posix.getenv("SHELL")) |shell| return shell;

    const uid = unix.getuid();
    const pwd = unix.getpwuid(uid);
    if (pwd != null) {
        const shell = pwd.*.pw_shell;
        return std.mem.span(shell);
    }

    return "/bin/sh";
}

pub const Shell = struct {
    io: std.fs.File,
    child_pid: std.c.pid_t,

    pub fn deinit(shell: Shell) void {
        shell.io.close();
    }
};
