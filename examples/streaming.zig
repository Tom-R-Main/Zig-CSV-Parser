const std = @import("std");
const csv = @import("csv_parser");

const Context = struct {
    rows: usize = 0,

    fn onRow(self: *@This(), row: csv.StreamingBorrowedRow) !void {
        self.rows += 1;
        std.debug.print("row {d}: {s}\n", .{ self.rows, try row.field(0) });
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input =
        "id,note\n" ++
        "1,\"hello\nworld\"\n" ++
        "2,done\n";

    var parser = try csv.StreamingBorrowedParser.init(allocator, .{});
    defer parser.deinit();

    var context: Context = .{};
    try parser.feed(input[0..12], Context, &context, Context.onRow);
    try parser.feed(input[12..], Context, &context, Context.onRow);
    try parser.finish(Context, &context, Context.onRow);
}
