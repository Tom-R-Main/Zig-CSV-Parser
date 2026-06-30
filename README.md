# Zig CSV Parser

A strict, zero-copy-capable CSV parser for Zig 0.16.

This parser is designed for practical CSV work: correctness first, borrowed APIs where they matter, and fast paths for common strict CSV input. It supports owning parses, borrowed tables, streaming callbacks, mmap input, header lookup, schema decoding, CSV writing, and csv-race-style field counting.

## Features

- Strict CSV parsing with quoted fields, escaped quotes, quoted newlines, CRLF, trailing empty fields, and UTF-8 BOM handling.
- Borrowed/zero-copy table parsing for caller-owned input.
- Fast default borrowed path for strict comma/double-quote CSV without diagnostics or non-default options.
- Streaming parser and streaming borrowed parser for chunked input.
- mmap helpers for file-backed parsing.
- Header indexes and `fieldByName` lookup.
- Struct decoding for simple schemas.
- CSV writing with quoting.
- Configurable delimiter, quote, trim mode, comments, tolerant quote handling, ragged row policy, expected field count, and row byte limits.
- ReleaseFast benchmark harness, including a `--race` field-counting mode.

## Requirements

- Zig `0.16.0`

```sh
zig version
```

## Install

### Vendor as a Single Module

Copy `csv_parser.zig` into your project, then add it to your `build.zig`:

```zig
const csv_parser = b.addModule("csv_parser", .{
    .root_source_file = b.path("vendor/zig-csv-parser/csv_parser.zig"),
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("csv_parser", csv_parser);
```

Use it from Zig:

```zig
const csv = @import("csv_parser");
```

### Use as a Zig Package

Once this repo is tagged, consumers can add it with Zig's package manager:

```sh
zig fetch --save git+https://github.com/Tom-R-Main/Zig-CSV-Parser.git#v0.1.0
```

Then wire the dependency module in `build.zig`:

```zig
const csv_dep = b.dependency("zig_csv_parser", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("csv_parser", csv_dep.module("csv_parser"));
```

## Quick Start

### Borrowed Table

Borrowed parsing stores compact metadata and returns field slices into the original input. The input must outlive the table.

```zig
const std = @import("std");
const csv = @import("csv_parser");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input =
        "name,age\n" ++
        "Ada,37\n" ++
        "Grace,85\n";

    var table = try csv.parseBorrowed(allocator, input, .{});
    defer table.deinit(allocator);

    const row = try table.row(1);
    std.debug.print("{s}\n", .{try row.field(0)});
}
```

### Headers

```zig
var table = try csv.parseBorrowedWithHeader(allocator, input, .{});
defer table.deinit(allocator);

const name = try table.field(0, "name");
```

### Owning Parse

```zig
var table = try csv.parse(allocator, input, .{});
defer table.deinit(allocator);
```

### Streaming Borrowed Rows

Streaming borrowed row fields are valid only until the callback returns.

```zig
const Context = struct {
    rows: usize = 0,

    fn onRow(self: *@This(), row: csv.StreamingBorrowedRow) !void {
        self.rows += 1;
        std.debug.print("first field: {s}\n", .{try row.field(0)});
    }
};

var parser = try csv.StreamingBorrowedParser.init(allocator, .{});
defer parser.deinit();

var context: Context = .{};
try parser.feed(input, Context, &context, Context.onRow);
try parser.finish(Context, &context, Context.onRow);
```

### Writing

```zig
const rows = [_]csv.Row{
    .{ .fields = &.{ "name", "city", "note" } },
    .{ .fields = &.{ "Ada", "New York, NY", "said \"hi\"" } },
};

try csv.writeRows(writer, &rows, .{});
```

## Options

```zig
const options = csv.ParseOptions{
    .delimiter = ',',
    .quote = '"',
    .trim = .none,
    .comment = null,
    .allow_bom = true,
    .tolerant = false,
    .skip_empty_rows = false,
    .ragged_row_policy = .allow,
    .expected_fields = null,
    .max_row_bytes = null,
    .track_locations = false,
};
```

Strict mode rejects malformed quote usage. Use `.tolerant = true` only for messy input where preserving progress is more important than strict CSV validation.

## Memory and Lifetimes

- `Table` owns field strings. Call `table.deinit(allocator)`.
- `BorrowedTable` owns metadata only. Field data points into the caller-owned input. Call `table.deinit(allocator)` while keeping the input alive for table use.
- `ArenaTable` is freed by `arena_table.deinit()`.
- `StreamingBorrowedRow` field slices are callback-scoped.
- `MappedInput` must be deinitialized with `mapped.deinit()`.

## Testing

```sh
zig fmt --check csv_parser.zig bench.zig build.zig examples/basic.zig examples/streaming.zig
zig build test
zig test -O ReleaseFast csv_parser.zig
zig build
zig build examples
```

The test suite covers:

- quoted delimiters
- escaped quotes
- quoted newlines
- CRLF
- trailing empty fields
- empty input and blank rows
- malformed quote rejection
- diagnostics
- BOM, comments, trim, empty-row skipping, tolerant mode
- ragged row policies
- borrowed metadata and quote arena behavior
- parallel borrowed parsing
- streaming chunk boundaries
- mmap parsing
- writing and custom delimiters

## Benchmarks

Synthetic benchmark:

```sh
zig build bench -- --synthetic-rows 300000
```

Real files:

```sh
zig build bench -- --files -n 50 path/to/file.csv
```

csv-race-style field counting:

```sh
zig build bench -- --race path/to/file.csv
```

Recent local ReleaseFast results on an Apple Silicon macOS machine showed the field-count path competitive with `csv-zero` and `lazycsv`, and the default borrowed table path around 1 GiB/s on favorable inputs. Benchmark results are hardware-, compiler-, and data-shape-dependent; rerun them locally before making performance claims.

## API Surface

Core:

- `parse`
- `parseArena`
- `parseBorrowed`
- `parseBorrowedFast`
- `parseBorrowedParallel`
- `parseWithDiagnostic`
- `parseBorrowedWithDiagnostic`
- `parseWithHeader`
- `parseBorrowedWithHeader`
- `StreamingParser`
- `StreamingBorrowedParser`
- `mapFile`
- `parseMapped`
- `countFieldsFast`
- `FastFieldIterator`
- `writeRecord`
- `writeRows`

## Development

```sh
zig build test
zig build examples
zig build bench -- --synthetic-rows 300000
```

Before publishing a tag:

```sh
zig fmt --check csv_parser.zig bench.zig build.zig examples/basic.zig examples/streaming.zig
zig build test
zig test -O ReleaseFast csv_parser.zig
zig build
zig build examples
```

## License

MIT
