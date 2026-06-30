const std = @import("std");
const csv = @import("csv_parser");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input =
        "name,age,city\n" ++
        "Ada,37,London\n" ++
        "Grace,85,\"New York, NY\"\n";

    var table = try csv.parseBorrowedWithHeader(allocator, input, .{});
    defer table.deinit(allocator);

    const name = try table.field(1, "name");
    const city = try table.field(1, "city");
    std.debug.print("{s} lived in {s}\n", .{ name, city });
}
