const std = @import("std");
const csv = @import("csv_parser.zig");

const TimedResult = struct {
    elapsed_ns: u64,
    rows: usize,
    fields: usize,
};

const streaming_bench_chunk_size = 64 * 1024;
const parallel_bench_min_chunk_size = 8 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    if (args.next()) |first_path| {
        if (std.mem.eql(u8, first_path, "--help") or std.mem.eql(u8, first_path, "-h")) {
            printUsage();
            return;
        }
        if (std.mem.eql(u8, first_path, "--synthetic-rows")) {
            const raw = args.next() orelse {
                printUsage();
                return error.InvalidArguments;
            };
            const row_count = try std.fmt.parseInt(usize, raw, 10);
            try runSyntheticBench(allocator, row_count);
            return;
        }
        if (std.mem.eql(u8, first_path, "--smoke")) {
            try runFileSmokeFromArgs(allocator, init.io, &args);
            return;
        }
        if (std.mem.eql(u8, first_path, "--files") or std.mem.eql(u8, first_path, "--file-bench")) {
            try runFileBench(allocator, init.io, &args);
            return;
        }
        if (std.mem.eql(u8, first_path, "--race") or std.mem.eql(u8, first_path, "--count-fields")) {
            try runCsvRaceCount(allocator, init.io, &args);
            return;
        }
        try runFileSmokeWithFirst(allocator, init.io, first_path, &args);
        return;
    }

    try runSyntheticBench(allocator, 50_000);
}

fn runSyntheticBench(allocator: std.mem.Allocator, row_count: usize) !void {
    const input = try generateCsv(allocator, row_count);
    defer allocator.free(input);

    const parse_iterations = 20;
    const borrowed_iterations = 100;
    const iterator_iterations = 200;
    const streaming_iterations = 100;

    const parse_result = try timeParse(allocator, input, parse_iterations);
    const borrowed_result = try timeBorrowed(allocator, input, borrowed_iterations);
    const fast_borrowed_result = try timeFastBorrowed(allocator, input, borrowed_iterations);
    const parallel_borrowed_result = try timeParallelBorrowed(allocator, input, borrowed_iterations);
    const iterator_result = try timeIterator(input, iterator_iterations);
    const streaming_result = try timeStreaming(allocator, input, streaming_iterations, streaming_bench_chunk_size);
    const streaming_borrowed_result = try timeStreamingBorrowed(allocator, input, streaming_iterations, streaming_bench_chunk_size);

    std.debug.print("input: {d} bytes\n", .{input.len});
    printThroughput("parse", input.len, parse_iterations, parse_result);
    printThroughput("borrowed table", input.len, borrowed_iterations, borrowed_result);
    printThroughput("fast borrowed table", input.len, borrowed_iterations, fast_borrowed_result);
    printThroughput("parallel borrowed", input.len, borrowed_iterations, parallel_borrowed_result);
    printThroughput("field iterator", input.len, iterator_iterations, iterator_result);
    printThroughput("streaming parser", input.len, streaming_iterations, streaming_result);
    printThroughput("streaming borrowed", input.len, streaming_iterations, streaming_borrowed_result);
}

fn runFileSmokeFromArgs(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
) !void {
    const first_path = args.next() orelse {
        printUsage();
        return error.InvalidArguments;
    };
    try runFileSmokeWithFirst(allocator, io, first_path, args);
}

fn runFileSmokeWithFirst(
    allocator: std.mem.Allocator,
    io: std.Io,
    first_path: []const u8,
    args: *std.process.Args.Iterator,
) !void {
    std.debug.print("path,bytes,rows,fields,status\n", .{});
    try smokePath(allocator, io, first_path);
    while (args.next()) |path| try smokePath(allocator, io, path);
}

fn smokePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const input = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024)) catch |err| {
        std.debug.print("{s},0,0,0,read-error:{s}\n", .{ path, @errorName(err) });
        return;
    };
    defer allocator.free(input);

    var status: []const u8 = "ok";
    var table = csv.parseBorrowed(allocator, input, .{}) catch |strict_err| blk: {
        status = @errorName(strict_err);
        break :blk csv.parseBorrowed(allocator, input, .{ .tolerant = true, .ragged_row_policy = .allow }) catch |tolerant_err| {
            std.debug.print("{s},{d},0,0,parse-error:{s}\n", .{ path, input.len, @errorName(tolerant_err) });
            return;
        };
    };
    defer table.deinit(allocator);

    std.debug.print("{s},{d},{d},{d},{s}\n", .{ path, input.len, table.rows.len, table.fields.len, status });
}

fn runFileBench(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
) !void {
    var requested_iterations: ?usize = null;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--iterations") or std.mem.eql(u8, arg, "-n")) {
            const raw = args.next() orelse {
                printUsage();
                return error.InvalidArguments;
            };
            requested_iterations = try std.fmt.parseInt(usize, raw, 10);
            if (requested_iterations.? == 0) return error.InvalidArguments;
            continue;
        }
        try paths.append(allocator, arg);
    }

    if (paths.items.len == 0) {
        printUsage();
        return error.InvalidArguments;
    }

    std.debug.print("path,bytes,iterations,parser,mib_per_s,rows_per_iter,fields_per_iter,elapsed_ns,status\n", .{});
    for (paths.items) |path| {
        try benchPath(allocator, io, path, requested_iterations);
    }
}

fn benchPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    requested_iterations: ?usize,
) !void {
    const input = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024)) catch |err| {
        printFileBenchError(path, 0, 0, "read", err);
        return;
    };
    defer allocator.free(input);

    const iterations = requested_iterations orelse defaultFileIterations(input.len);

    const parse_result = timeParse(allocator, input, iterations) catch |err| {
        printFileBenchError(path, input.len, iterations, "owning parse", err);
        return;
    };
    printFileBenchResult(path, input.len, iterations, "owning parse", parse_result);

    const borrowed_result = timeBorrowed(allocator, input, iterations) catch |err| {
        printFileBenchError(path, input.len, iterations, "borrowed table", err);
        return;
    };
    printFileBenchResult(path, input.len, iterations, "borrowed table", borrowed_result);

    const fast_borrowed_result = timeFastBorrowed(allocator, input, iterations) catch |err| {
        printFileBenchError(path, input.len, iterations, "fast borrowed table", err);
        return;
    };
    printFileBenchResult(path, input.len, iterations, "fast borrowed table", fast_borrowed_result);

    const parallel_borrowed_result = timeParallelBorrowed(allocator, input, iterations) catch |err| {
        printFileBenchError(path, input.len, iterations, "parallel borrowed", err);
        return;
    };
    printFileBenchResult(path, input.len, iterations, "parallel borrowed", parallel_borrowed_result);

    const iterator_result = timeIterator(input, iterations) catch |err| {
        printFileBenchError(path, input.len, iterations, "field iterator", err);
        return;
    };
    printFileBenchResult(path, input.len, iterations, "field iterator", iterator_result);

    const streaming_result = timeStreaming(allocator, input, iterations, streaming_bench_chunk_size) catch |err| {
        printFileBenchError(path, input.len, iterations, "streaming parser", err);
        return;
    };
    printFileBenchResult(path, input.len, iterations, "streaming parser", streaming_result);

    const streaming_borrowed_result = timeStreamingBorrowed(allocator, input, iterations, streaming_bench_chunk_size) catch |err| {
        printFileBenchError(path, input.len, iterations, "streaming borrowed", err);
        return;
    };
    printFileBenchResult(path, input.len, iterations, "streaming borrowed", streaming_borrowed_result);
}

fn runCsvRaceCount(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
) !void {
    _ = allocator;
    const path = args.next() orelse {
        printUsage();
        return error.InvalidArguments;
    };
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var mapped = try csv.mapFile(file, io);
    defer mapped.deinit();

    const fields = try csv.countFieldsFast(.{}, mapped.data);

    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{d}\n", .{fields});
    try stdout.flush();
}

fn generateCsv(allocator: std.mem.Allocator, row_count: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    try output.writer.writeAll("id,name,city,note\n");
    for (0..row_count) |row_index| {
        try output.writer.print(
            "{d},name-{d},\"New York, NY\",\"said \"\"hi\"\" on row {d}\"\n",
            .{ row_index, row_index, row_index },
        );
    }

    return try output.toOwnedSlice();
}

fn timeParse(allocator: std.mem.Allocator, input: []const u8, iterations: usize) !TimedResult {
    const started_ns = try nowNs();
    var rows: usize = 0;
    var fields: usize = 0;

    for (0..iterations) |_| {
        var table = try csv.parse(allocator, input, .{});
        rows += table.rows.len;
        for (table.rows) |row| fields += row.fields.len;
        table.deinit(allocator);
    }

    return .{
        .elapsed_ns = @max(try nowNs() - started_ns, 1),
        .rows = rows,
        .fields = fields,
    };
}

fn timeBorrowed(allocator: std.mem.Allocator, input: []const u8, iterations: usize) !TimedResult {
    const started_ns = try nowNs();
    var rows: usize = 0;
    var fields: usize = 0;

    for (0..iterations) |_| {
        var table = try csv.parseBorrowed(allocator, input, .{});
        rows += table.rows.len;
        fields += table.fields.len;
        std.mem.doNotOptimizeAway(table.quote_arena.len);
        table.deinit(allocator);
    }

    return .{
        .elapsed_ns = @max(try nowNs() - started_ns, 1),
        .rows = rows,
        .fields = fields,
    };
}

fn timeFastBorrowed(allocator: std.mem.Allocator, input: []const u8, iterations: usize) !TimedResult {
    const started_ns = try nowNs();
    var rows: usize = 0;
    var fields: usize = 0;

    for (0..iterations) |_| {
        var table = try csv.parseBorrowedFast(.{}, allocator, input);
        rows += table.rows.len;
        fields += table.fields.len;
        std.mem.doNotOptimizeAway(table.quote_arena.len);
        table.deinit(allocator);
    }

    return .{
        .elapsed_ns = @max(try nowNs() - started_ns, 1),
        .rows = rows,
        .fields = fields,
    };
}

fn timeParallelBorrowed(allocator: std.mem.Allocator, input: []const u8, iterations: usize) !TimedResult {
    const started_ns = try nowNs();
    var rows: usize = 0;
    var fields: usize = 0;

    for (0..iterations) |_| {
        var table = try csv.parseBorrowedParallel(allocator, input, .{}, .{
            .min_chunk_bytes = parallel_bench_min_chunk_size,
        });
        rows += table.rows.len;
        fields += table.fields.len;
        std.mem.doNotOptimizeAway(table.quote_arena.len);
        table.deinit(allocator);
    }

    return .{
        .elapsed_ns = @max(try nowNs() - started_ns, 1),
        .rows = rows,
        .fields = fields,
    };
}

fn timeIterator(input: []const u8, iterations: usize) !TimedResult {
    const started_ns = try nowNs();
    var rows: usize = 0;
    var fields: usize = 0;

    for (0..iterations) |_| {
        var iterator = try csv.FieldIterator.init(input, .{});
        while (try iterator.next()) |field| {
            fields += 1;
            if (field.row_end) rows += 1;
        }
    }

    return .{
        .elapsed_ns = @max(try nowNs() - started_ns, 1),
        .rows = rows,
        .fields = fields,
    };
}

fn timeStreaming(allocator: std.mem.Allocator, input: []const u8, iterations: usize, chunk_size: usize) !TimedResult {
    const Context = struct {
        rows: usize = 0,
        fields: usize = 0,

        fn onRow(self: *@This(), row: csv.Row) !void {
            self.rows += 1;
            self.fields += row.fields.len;
        }
    };

    const started_ns = try nowNs();
    var total_rows: usize = 0;
    var total_fields: usize = 0;

    for (0..iterations) |_| {
        var parser = try csv.StreamingParser.init(allocator, .{});
        defer parser.deinit();

        var context: Context = .{};
        var offset: usize = 0;
        while (offset < input.len) {
            const end = @min(offset + chunk_size, input.len);
            try parser.feed(input[offset..end], Context, &context, Context.onRow);
            offset = end;
        }
        try parser.finish(Context, &context, Context.onRow);

        total_rows += context.rows;
        total_fields += context.fields;
    }

    return .{
        .elapsed_ns = @max(try nowNs() - started_ns, 1),
        .rows = total_rows,
        .fields = total_fields,
    };
}

fn timeStreamingBorrowed(allocator: std.mem.Allocator, input: []const u8, iterations: usize, chunk_size: usize) !TimedResult {
    const Context = struct {
        rows: usize = 0,
        fields: usize = 0,

        fn onRow(self: *@This(), row: csv.StreamingBorrowedRow) !void {
            self.rows += 1;
            self.fields += row.len();
        }
    };

    const started_ns = try nowNs();
    var total_rows: usize = 0;
    var total_fields: usize = 0;

    for (0..iterations) |_| {
        var parser = try csv.StreamingBorrowedParser.init(allocator, .{});
        defer parser.deinit();

        var context: Context = .{};
        var offset: usize = 0;
        while (offset < input.len) {
            const end = @min(offset + chunk_size, input.len);
            try parser.feed(input[offset..end], Context, &context, Context.onRow);
            offset = end;
        }
        try parser.finish(Context, &context, Context.onRow);

        total_rows += context.rows;
        total_fields += context.fields;
    }

    return .{
        .elapsed_ns = @max(try nowNs() - started_ns, 1),
        .rows = total_rows,
        .fields = total_fields,
    };
}

fn nowNs() error{TimerUnavailable}!u64 {
    var timespec: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &timespec))) {
        .SUCCESS => {
            const ns = @as(i128, timespec.sec) * std.time.ns_per_s + timespec.nsec;
            return @intCast(ns);
        },
        else => return error.TimerUnavailable,
    }
}

fn printThroughput(label: []const u8, input_len: usize, iterations: usize, result: TimedResult) void {
    const bytes_processed = input_len * iterations;
    const bytes_per_second = (@as(u128, bytes_processed) * std.time.ns_per_s) / result.elapsed_ns;
    const mib_per_second = bytes_per_second / (1024 * 1024);

    std.debug.print(
        "{s}: {d} iterations, {d} MiB/s, {d} rows, {d} fields, {d} ns\n",
        .{ label, iterations, mib_per_second, result.rows, result.fields, result.elapsed_ns },
    );
}

fn defaultFileIterations(input_len: usize) usize {
    const target_bytes: usize = 256 * 1024 * 1024;
    const bytes = @max(input_len, 1);
    return std.math.clamp(target_bytes / bytes, 1, 200);
}

fn printFileBenchResult(
    path: []const u8,
    input_len: usize,
    iterations: usize,
    parser_name: []const u8,
    result: TimedResult,
) void {
    printCsvString(path);
    const rows_per_iter = result.rows / iterations;
    const fields_per_iter = result.fields / iterations;
    std.debug.print(
        ",{d},{d},\"{s}\",{d},{d},{d},{d},ok\n",
        .{
            input_len,
            iterations,
            parser_name,
            mibPerSecond(input_len, iterations, result.elapsed_ns),
            rows_per_iter,
            fields_per_iter,
            result.elapsed_ns,
        },
    );
}

fn printFileBenchError(
    path: []const u8,
    input_len: usize,
    iterations: usize,
    parser_name: []const u8,
    err: anyerror,
) void {
    printCsvString(path);
    std.debug.print(
        ",{d},{d},\"{s}\",0,0,0,0,error:{s}\n",
        .{ input_len, iterations, parser_name, @errorName(err) },
    );
}

fn mibPerSecond(input_len: usize, iterations: usize, elapsed_ns: u64) u128 {
    const bytes_processed = input_len * iterations;
    const safe_elapsed = @max(elapsed_ns, 1);
    const bytes_per_second = (@as(u128, bytes_processed) * std.time.ns_per_s) / safe_elapsed;
    return bytes_per_second / (1024 * 1024);
}

fn printCsvString(value: []const u8) void {
    std.debug.print("\"", .{});
    for (value) |byte| {
        switch (byte) {
            '"' => std.debug.print("\"\"", .{}),
            '\n' => std.debug.print("\\n", .{}),
            '\r' => std.debug.print("\\r", .{}),
            else => std.debug.print("{c}", .{byte}),
        }
    }
    std.debug.print("\"", .{});
}

fn printUsage() void {
    std.debug.print(
        \\usage:
        \\  zig build bench
        \\  zig build bench -- --synthetic-rows <rows>
        \\  zig build bench -- --files [-n ITERATIONS] <csv>...
        \\  zig build bench -- --smoke <csv>...
        \\  zig build bench -- --race <csv>
        \\
    , .{});
}
