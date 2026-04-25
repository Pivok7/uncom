const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cwd = std.Io.Dir.cwd;

const io_buf_size = 1024;

const Flags = packed struct {
    remove: bool = false,
    force: bool = false,
    quiet: bool = false,
    local: bool = false,
};

fn stdinReadUntilDeliminerAlloc(allocator: Allocator, io: Io, deliminer: u8) ![]const u8 {
    var stdin_buf: [io_buf_size]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &stdin_buf);

    var alloc_writer = Io.Writer.Allocating.init(allocator);

    _ = try stdin.interface.streamDelimiter(&alloc_writer.writer, deliminer);

    return try alloc_writer.toOwnedSlice();
}

fn fileExists(io: Io, file_path: []const u8) !bool {
    cwd().access(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return !false,
    };
    return true;
}

fn printHelp() void {
    std.debug.print("Uncom - universal uncompressor\n", .{});
    std.debug.print("How to use:\n", .{});
    std.debug.print("uncom [file_path] [flags]\n", .{});
    std.debug.print("-r     --remove     Remove archive when finished\n", .{});
    std.debug.print("-f     --force      Force override output directory\n", .{});
    std.debug.print("-q     --quiet      Minimize displayed info\n", .{});
    std.debug.print("-l     --local      Unpack all files to this directory\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var flags: Flags = .{};

    const args = try init.minimal.args.toSlice(init.arena.allocator());

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
                    },
                }
            }
            continue;
        } else {
            input_file_or_null = arg;
            continue;
        }
    }

    const input_file = input_file_or_null orelse {
        std.log.err("No input file!", .{});
        std.process.exit(2);
    };

    if (!try fileExists(io, input_file)) {
        std.log.err("File \"{s}\" does not exist!", .{input_file});
        std.process.exit(1);
    }

    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(allocator);

    const full_file_path = try cwd().realPathFileAlloc(io, input_file, allocator);
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
        try runCommand(allocator, io, command.items);

        if (flags.remove) {
            try cwd().deleteFile(io, full_file_path);
            if (!flags.quiet) std.debug.print("Removed: {s}\n", .{input_file});
        }
        // 7z
    } else if (std.mem.endsWith(u8, input_file, ".7z")) {
        try command.append(allocator, "7z");
        try command.append(allocator, "x");
        if (flags.force) try command.append(allocator, "-aoa");
        if (flags.quiet) try command.append(allocator, "-bso0");
        try command.append(allocator, full_file_path);

        var output_dir: std.ArrayList(u8) = .empty;
        defer output_dir.deinit(allocator);

        if (!flags.local) {
            try output_dir.appendSlice(allocator, "-o");
            try output_dir.appendSlice(allocator, full_file_path[0..std.mem.lastIndexOf(u8, full_file_path, ".7z").?]);
        }

        try command.append(allocator, output_dir.items);

        if (!flags.quiet) std.debug.print("Working...\n", .{});
        try runCommand(allocator, io, command.items);

        if (flags.remove) {
            try cwd().deleteFile(io, full_file_path);
            if (!flags.quiet) std.debug.print("Removed: {s}\n", .{input_file});
        }
        // Tar gz, xz and bz2
    } else if (std.mem.endsWith(u8, input_file, ".tar.gz") or
        std.mem.endsWith(u8, input_file, ".tar.xz") or
        std.mem.endsWith(u8, input_file, ".tar.bz2"))
    {
        try command.append(allocator, "tar");
        try command.append(allocator, "-xf");

        try command.append(allocator, full_file_path);

        const output_dir_path = full_file_path[0..std.mem.lastIndexOf(u8, full_file_path, ".tar.").?];

        if (!flags.local) {
            if (flags.force) try cwd().deleteTree(io, output_dir_path);

            if (try fileExists(io, output_dir_path)) {
                std.debug.print("Directory already exists. Override? [y/N] ", .{});

                const user_input = try stdinReadUntilDeliminerAlloc(allocator, io, '\n');
                defer allocator.free(user_input);

                if (std.mem.eql(u8, user_input, "y") or std.mem.eql(u8, user_input, "Y")) {
                    try cwd().deleteTree(io, output_dir_path);
                    try cwd().createDirPath(io, output_dir_path);
                } else {
                    std.debug.print("Exiting...\n", .{});
                    std.process.exit(0);
                }
            } else {
                try cwd().createDirPath(io, output_dir_path);
            }

            try command.append(allocator, "-C");
            try command.append(allocator, output_dir_path);
        }

        if (!flags.quiet) std.debug.print("Working...\n", .{});
        try runCommand(allocator, io, command.items);

        if (flags.remove) {
            try cwd().deleteFile(io, full_file_path);
            if (!flags.quiet) std.debug.print("Removed: {s}\n", .{input_file});
        }
    } else {
        std.debug.print("File type not supported\n", .{});
        std.process.exit(1);
    }

    if (!flags.quiet) std.debug.print("Done!\n", .{});
}

fn runCommand(allocator: Allocator, io: Io, command: []const []const u8) !void {
    // Initialize the child process
    const result = try std.process.run(allocator, io, .{
        .argv = command,
    });

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);


    // Check exit status
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.log.err("Command failed with exit code: {d}\n", .{code});
                std.log.err("--- stdout ---\n", .{});
                std.debug.print("{s}\n", .{result.stdout});
                std.log.err("--- stderr ---\n", .{});
                std.debug.print("{s}\n", .{result.stderr});
            }
        },
        else => std.log.err("Process terminated abnormally\n", .{}),
    }
}
