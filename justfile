
# The default shell to use when starting the terminal.
export SHELL := "/usr/bin/bash"

# Should the tracy profiler be enabled?
TRACY := "false"

# Should we build with LLVM or the Zig's custom backend?
LLVM := "true"

[positional-arguments]
run *args:
    zig build -freference-trace -Dtracy={{TRACY}} -Duse-llvm={{LLVM}} run "$@"

watch:
    zig build -fincremental -Duse-llvm=false --watch --prominent-compile-errors

build:
    zig build

