
# Should the tracy profiler be enabled?
TRACY := "false"

# Should we build with LLVM or the Zig's custom backend?
LLVM := "true"

# Zig optimization level.
OPTIMIZE := "Debug"

FLAGS := " --prominent-compile-errors" \
       + " -freference-trace" \
       + " -Doptimize=" + OPTIMIZE \
       + " -Duse-llvm=" + LLVM \
       + " -Dtracy=" + TRACY \
       + ""

[positional-arguments]
run *args:
    zig build {{FLAGS}} run "$@"

build:
    zig build {{FLAGS}}

watch:
    zig build {{FLAGS}} --watch

[positional-arguments]
debug *args: build
    lldb -o run -- ./zig-out/bin/shitty {{args}}

