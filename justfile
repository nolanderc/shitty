set export

SHELL := "/usr/bin/bash"

[positional-arguments]
run *args:
    zig build -freference-trace run "$@"

watch:
    zig build -fincremental -Duse-llvm=false --watch --prominent-compile-errors

build:
    zig build

