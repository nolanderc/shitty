
run:
    zig build -freference-trace run

watch:
    zig build -freference-trace -fincremental -Duse-llvm=false --watch

build:
    zig build

