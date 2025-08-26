const std = @import("std");
const Allocator = std.mem.Allocator;

const Flags = packed struct{
    remove: bool = false,
    force: bool = false,
    quiet: bool = false,
    local: bool = false,
};

fn stdinReadUntilDeliminerAlloc(allocator: Allocator, deliminer: u8) ![]const u8 {
    var stdin_buf: [1]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buf);

    var arr = std.ArrayList(u8){};
    defer arr.deinit(allocator);

    while (true) {
        const read = try stdin.interface.takeByte();

        if (read != deliminer) {
            try arr.append(allocator, read);
        } else {
            break;
        }
    }

    return try arr.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var flags: Flags = .{};

    const args = try std.process.argsAlloc(allocator);
    errdefer std.process.argsFree(allocator, args);

    if (args.len == 1) {
        printHelp();
        std.process.exit(0);
    }

    var input_file_or_null: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-r") or (std.mem.eql(u8, arg, "--remove"))) {
            flags.remove = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-f") or (std.mem.eql(u8, arg, "--force"))) {
            flags.force = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            flags.quiet = true;
            continue;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--local")) {
            flags.local = true;
            continue;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            for (arg) |char| {
                switch (char) {
                    '-' => continue,
                    'r' => flags.remove = true,
                    'f' => flags.force = true,
                    'q' => flags.quiet = true,
                    'l' => flags.local = true,
                    else => {
                        std.log.err("Invalid flag \"{c}\"", .{char});
                        std.process.exit(2);
                    }
                }
            }
            continue;
        }
        else {
            input_file_or_null = arg;
            continue;
        }
    }

    const input_file = input_file_or_null orelse {
        std.log.err("No input file!", .{});
        std.process.exit(2);
    };

    if (!try fileExists(input_file)) {
        std.log.err("File \"{s}\" does not exist!", .{input_file});
        std.process.exit(1);
    }

    var command = std.ArrayList([]const u8){};
    defer command.deinit(allocator);

    const full_file_path = try std.fs.cwd().realpathAlloc(allocator, input_file);
    defer allocator.free(full_file_path);

    // Zip
    if (std.mem.endsWith(u8, input_file, ".zip")) {
        try command.append(allocator, "unzip");
        if (flags.force) try command.append(allocator, "-o");
        if (flags.quiet) try command.append(allocator, "-q");
        try command.append(allocator, full_file_path);

        if (!flags.local) {
            const output_dir_path = full_file_path[0..std.mem.lastIndexOf(u8, full_file_path, ".zip").?];
            try command.append(allocator, "-d");
            try command.append(allocator, output_dir_path);
        }

        if (!flags.quiet) std.debug.print("Working...\n", .{});
        try runCommand(allocator, command.items);

        if (flags.remove) {
            try std.fs.cwd().deleteFile(full_file_path);
            if (!flags.quiet) std.debug.print("Removed: {s}\n", .{input_file});
        }
    // 7z
    } else if (std.mem.endsWith(u8, input_file, ".7z")) {
        try command.append(allocator, "7z");
        try command.append(allocator, "x");
        if (flags.force) try command.append(allocator, "-aoa");
        if (flags.quiet) try command.append(allocator, "-bso0");
        try command.append(allocator, full_file_path);

        var output_dir = std.ArrayList(u8){};
        defer output_dir.deinit(allocator);

        if (!flags.local) {
            try output_dir.appendSlice(allocator, "-o");
            try output_dir.appendSlice(
                allocator,
                full_file_path[0..std.mem.lastIndexOf(u8, full_file_path, ".7z").?]
            );
        }

        try command.append(allocator, output_dir.items);

        if (!flags.quiet) std.debug.print("Working...\n", .{});
        try runCommand(allocator, command.items);

        if (flags.remove) {
            try std.fs.cwd().deleteFile(full_file_path);
            if (!flags.quiet) std.debug.print("Removed: {s}\n", .{input_file});
        }
    // Tar gz
    } else if (
        std.mem.endsWith(u8, input_file, ".tar.gz") or
        std.mem.endsWith(u8, input_file, "tar.xz") or
        std.mem.endsWith(u8, input_file, "tar.bz2")
    ) {
        try command.append(allocator, "tar");
        try command.append(allocator, "-xf");

        try command.append(allocator, full_file_path);

        const output_dir_path = full_file_path[0..std.mem.lastIndexOf(u8, full_file_path, ".tar.").?];

        if (!flags.local) {
            if (flags.force) try std.fs.cwd().deleteTree(output_dir_path);

            if (try fileExists(output_dir_path)) {
                std.debug.print("Directory already exists. Override? [y/N] ", .{});

                const user_input = try stdinReadUntilDeliminerAlloc(allocator, '\n');
                defer allocator.free(user_input);

                if (std.mem.eql(u8, user_input, "y") or std.mem.eql(u8, user_input, "Y")) {
                    try std.fs.cwd().deleteTree(output_dir_path);
                    try std.fs.cwd().makeDir(output_dir_path);
                } else {
                    std.debug.print("Exiting...\n", .{});
                    std.process.exit(0);
                }
            } else {
                try std.fs.cwd().makeDir(output_dir_path);
            }

            try command.append(allocator, "-C");
            try command.append(allocator, output_dir_path);
        }

        if (!flags.quiet) std.debug.print("Working...\n", .{});
        try runCommand(allocator, command.items);

        if (flags.remove) {
            try std.fs.cwd().deleteFile(full_file_path);
            if (!flags.quiet) std.debug.print("Removed: {s}\n", .{input_file});
        }
    } else {
        std.debug.print("File type not supported\n", .{});
        std.process.exit(1);
    }

    if (!flags.quiet) std.debug.print("Done!\n", .{});
}

fn runCommand(allocator: Allocator, command: []const []const u8) !void {

    // Initialize the child process
    var child = std.process.Child.init(command, allocator);
    _ = try child.spawn(); // Start the process

    // Wait for the process to exit
    const term = try child.wait();

    // Check exit status
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Command failed with exit code: {d}\n", .{code});
            }
        },
        else => std.debug.print("Process terminated abnormally\n", .{}),
    }
}

fn printHelp() void {
    std.debug.print("Uncom - universal uncompressor\n", .{});
    std.debug.print("How to use:\n", .{});
    std.debug.print("uncom [file_path] [flags]\n", .{});
    std.debug.print("-r     --remove     Remove archive when finished\n", .{});
    std.debug.print("-f     --force      Force override output directory\n", .{});
    std.debug.print("-q     --quiet      Minimize displayed info\n", .{});
    std.debug.print("-l     --local      Unpack all files to this folder\n", .{});
}

fn fileExists(file_path: []const u8) !bool {
    std.fs.cwd().access(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return !false,
    };
    return true;
}
