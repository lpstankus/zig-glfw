const std = @import("std");

const base_src = [_][]const u8{
    "src/context.c",
    "src/egl_context.c",
    "src/init.c",
    "src/input.c",
    "src/monitor.c",
    "src/null_init.c",
    "src/null_joystick.c",
    "src/null_monitor.c",
    "src/null_window.c",
    "src/osmesa_context.c",
    "src/platform.c",
    "src/vulkan.c",
    "src/window.c",
};

const macos_src = [_][]const u8{
    // base
    "src/cocoa_time.c",
    "src/posix_module.c",
    "src/posix_thread.c",
    // cocoa
    "src/cocoa_init.m",
    "src/cocoa_joystick.m",
    "src/cocoa_monitor.m",
    "src/cocoa_window.m",
    "src/nsgl_context.m",
};

const windows_src = [_][]const u8{
    // base
    "src/win32_module.c",
    "src/win32_time.c",
    "src/win32_thread.c",
    // win32
    "src/win32_init.c",
    "src/win32_joystick.c",
    "src/win32_monitor.c",
    "src/win32_window.c",
    "src/wgl_context.c",
};

const linux_src = [_][]const u8{
    "src/posix_module.c",
    "src/posix_time.c",
    "src/posix_thread.c",
};

// GLFW_BUILD_X11
const x11_src = [_][]const u8{
    "src/x11_init.c",
    "src/x11_monitor.c",
    "src/x11_window.c",
    "src/xkb_unicode.c",
    "src/glx_context.c",
    "src/linux_joystick.c",
    "src/posix_poll.c",
};

// GLFW_BUILD_WAYLAND
const wayland_src = [_][]const u8{
    "src/wl_init.c",
    "src/wl_monitor.c",
    "src/wl_window.c",
    "src/xkb_unicode.c",
    "src/linux_joystick.c",
    "src/posix_poll.c",
};

const wayland_protocol_files = [_][]const u8{
    "wayland",
    "viewporter",
    "xdg-shell",
    "idle-inhibit-unstable-v1",
    "pointer-constraints-unstable-v1",
    "relative-pointer-unstable-v1",
    "fractional-scale-v1",
    "xdg-activation-v1",
    "xdg-decoration-unstable-v1",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared = b.option(bool, "shared", "Build as a shared library") orelse false;

    const build_x11 = b.option(bool, "x11", "Build support for X11") orelse true;
    const build_wayland = b.option(bool, "wayland", "Build support for Wayland") orelse true;

    const lib = std.Build.Step.Compile.create(b, .{
        .name = "glfw",
        .version = .{ .major = 3, .minor = 4, .patch = 0 },
        .kind = .lib,
        .linkage = if (shared) .dynamic else .static,
        .root_module = .{
            .target = target,
            .optimize = optimize,
        },
    });
    lib.addIncludePath(b.path("include/GLFW"));
    lib.linkLibC();

    if (shared) lib.defineCMacro("_GLFW_BUILD_DLL", "");

    lib.addCSourceFiles(.{ .files = &base_src });
    switch (target.result.os.tag) {
        .windows => {
            std.log.info("Including Win32 support", .{});
            lib.addCSourceFiles(.{ .files = &windows_src });
            lib.defineCMacro("_GLFW_WIN32", "");
        },
        .macos => {
            std.debug.panic("macOS support not implemented", .{});
            // FIXME: missing xcode stuff
            // std.log.info("Including Cocoa support", .{});
            // lib.addCSourceFiles(.{ .files = &macos_src });
            // lib.defineCMacro("_GLFW_COCOA", "");
        },
        .linux => {
            if (build_x11) std.log.info("Including X11 support", .{});
            if (build_wayland) std.log.info("Including Wayland support", .{});

            lib.addCSourceFiles(.{ .files = &linux_src });

            var scripts_step = b.step(
                "header scripts",
                "scripts necessary to prepare the header files for proper compilation",
            );

            const wf = b.addWriteFiles();
            wf.step.dependOn(scripts_step);

            if (build_x11) {
                lib.addCSourceFiles(.{ .files = &x11_src });
                lib.defineCMacro("_GLFW_X11", "");

                const simple_dependencies = [_][]const u8{
                    "xorgproto",
                    "libX11",
                    "xrandr",
                    "xrender",
                    "xinerama",
                    "xfixes",
                    "xext",
                    "xi",
                };
                for (simple_dependencies) |simple_dependency| {
                    const dep = b.lazyDependency(simple_dependency, .{}) orelse
                        std.debug.panic("Dependency \"{s}\" not found", .{simple_dependency});
                    lib.addIncludePath(dep.path("include/"));
                }

                // xcursor
                {
                    const xcursor = b.lazyDependency("xcursor", .{}) orelse
                        std.debug.panic("Depetdency \"xcursor\" not found", .{});
                    const xcursor_version = .{ .major = 1, .minor = 2, .rev = 3 };

                    const cmd = b.addSystemCommand(&[_][]const u8{"sed"});
                    var buf = [_]u8{0} ** 1024;
                    cmd.addArg(std.fmt.bufPrint(
                        &buf,
                        "-e s/#undef XCURSOR_LIB_MAJOR/#define XCURSOR_LIB_MAJOR {}/",
                        .{xcursor_version.major},
                    ) catch unreachable);
                    cmd.addArg(std.fmt.bufPrint(
                        &buf,
                        "-e s/#undef XCURSOR_LIB_MAJOR/#define XCURSOR_LIB_MINOR {}/",
                        .{xcursor_version.minor},
                    ) catch unreachable);
                    cmd.addArg(std.fmt.bufPrint(
                        &buf,
                        "-e s/#undef XCURSOR_LIB_REVISION/#define XCURSOR_LIB_REVISION {}/",
                        .{xcursor_version.rev},
                    ) catch unreachable);
                    cmd.addFileArg(xcursor.path("include/X11/Xcursor/Xcursor.h.in"));

                    const out_file = cmd.captureStdOut();

                    scripts_step.dependOn(&cmd.step);
                    _ = wf.addCopyFile(out_file, "X11/Xcursor/Xcursor.h");
                }
            }

            if (build_wayland) {
                lib.addCSourceFiles(.{ .files = &wayland_src });
                lib.defineCMacro("_GLFW_WAYLAND", "");

                // xkbcommon lib (only headers used)
                {
                    const xkb = b.lazyDependency("xkbcommon", .{}) orelse
                        std.debug.panic("Dependency \"xkbcommon\" not found", .{});
                    lib.addIncludePath(xkb.path("include/"));
                }

                // wayland headers
                {
                    const wlh = b.lazyDependency("wayland_headers", .{}) orelse
                        std.debug.panic("Dependency \"wayland_headers\" not found", .{});
                    const wayland_version = .{ .major = 1, .minor = 23, .micro = 1 };

                    lib.addIncludePath(wlh.path("src/"));

                    const cmd = b.addSystemCommand(&[_][]const u8{"sed"});
                    var buf = [_]u8{0} ** 1024;
                    cmd.addArg(std.fmt.bufPrint(
                        &buf,
                        "-e s/@WAYLAND_VERSION_MAJOR@/{}/",
                        .{wayland_version.major},
                    ) catch unreachable);
                    cmd.addArg(std.fmt.bufPrint(
                        &buf,
                        "-e s/@WAYLAND_VERSION_MINOR@/{}/",
                        .{wayland_version.minor},
                    ) catch unreachable);
                    cmd.addArg(std.fmt.bufPrint(
                        &buf,
                        "-e s/@WAYLAND_VERSION_MICRO/{}/",
                        .{wayland_version.micro},
                    ) catch unreachable);
                    cmd.addArg(std.fmt.bufPrint(
                        &buf,
                        "-e s/@WAYLAND_VERSION/\"{}.{}.{}\"/",
                        .{ wayland_version.major, wayland_version.minor, wayland_version.micro },
                    ) catch unreachable);
                    cmd.addFileArg(wlh.path("src/wayland-version.h.in"));

                    const out_file = cmd.captureStdOut();

                    scripts_step.dependOn(&cmd.step);
                    _ = wf.addCopyFile(out_file, "wayland-version.h");
                }

                // wayland protocol files
                inline for (wayland_protocol_files) |file| {
                    const protocol_path = b.path("deps/wayland/" ++ file ++ ".xml");
                    {
                        const header_file = file ++ "-client-protocol.h";
                        const cmd = b.addSystemCommand(&[_][]const u8{
                            "wayland-scanner",
                            "client-header",
                            protocol_path.getPath(b),
                        });
                        const out_file = cmd.addOutputFileArg(header_file);

                        scripts_step.dependOn(&cmd.step);
                        _ = wf.addCopyFile(out_file, header_file);
                    }
                    {
                        const code_file = file ++ "-client-protocol-code.h";
                        const cmd = b.addSystemCommand(&[_][]const u8{
                            "wayland-scanner",
                            "private-code",
                            protocol_path.getPath(b),
                        });
                        const out_file = cmd.addOutputFileArg(code_file);

                        scripts_step.dependOn(&cmd.step);
                        _ = wf.addCopyFile(out_file, code_file);
                    }
                }
            }

            lib.step.dependOn(&wf.step);
            lib.addIncludePath(wf.getDirectory());
        },
        else => |tag| std.debug.panic("Unsupported OS {}", .{tag}),
    }

    lib.installHeadersDirectory(b.path("include/GLFW"), "GLFW", .{});
    lib.installHeader(b.path("deps/glad/vulkan.h"), "vulkan/vulkan.h");
    b.installArtifact(lib);
}
