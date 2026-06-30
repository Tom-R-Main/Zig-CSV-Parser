const std = @import("std");

pub const ParseError = error{
    InvalidOptions,
    RaggedRow,
    MissingHeader,
    DuplicateHeader,
    UnknownColumn,
    UnexpectedQuote,
    UnexpectedByteAfterQuote,
    UnterminatedQuote,
    InputTooLarge,
    RowTooLarge,
} || std.mem.Allocator.Error;

pub const DecodeError = ParseError || std.fmt.ParseIntError || std.fmt.ParseFloatError || error{
    InvalidBool,
    UnsupportedSchemaType,
};

pub const TrimMode = enum {
    none,
    unquoted,
    all,
};

pub const RaggedRowPolicy = enum {
    allow,
    error_on_ragged,
    pad,
    truncate,
};

pub const ParseOptions = struct {
    delimiter: u8 = ',',
    quote: u8 = '"',
    trim: TrimMode = .none,
    comment: ?u8 = null,
    allow_bom: bool = true,
    tolerant: bool = false,
    skip_empty_rows: bool = false,
    ragged_row_policy: RaggedRowPolicy = .allow,
    expected_fields: ?usize = null,
    max_row_bytes: ?usize = null,
    track_locations: bool = false,
};

pub const FastFieldOptions = struct {
    delimiter: u8 = ',',
    quote: u8 = '"',
    allow_bom: bool = true,
};

pub const ParallelParseOptions = struct {
    min_chunk_bytes: usize = 8 * 1024 * 1024,
    max_threads: usize = 0,
};

pub const WriteOptions = struct {
    delimiter: u8 = ',',
    quote: u8 = '"',
    line_ending: []const u8 = "\n",
    quote_empty: bool = false,
    trailing_line_ending: bool = true,
};

pub const ParseErrorCode = enum {
    invalid_options,
    ragged_row,
    missing_header,
    duplicate_header,
    unknown_column,
    unexpected_quote,
    unexpected_byte_after_quote,
    unterminated_quote,
    input_too_large,
    row_too_large,
    out_of_memory,
};

pub const ParseLocation = struct {
    row: usize,
    column: usize,
    byte_offset: usize,
    line: usize,
    line_column: usize,
};

pub const ParseDiagnostic = struct {
    code: ParseErrorCode,
    location: ParseLocation,
    message: []const u8,
};

pub const FieldSlice = struct {
    data: []const u8,
    row_end: bool,
    quoted: bool,
    needs_unescape: bool,
    location: ParseLocation,
};

pub const Row = struct {
    fields: []const []const u8,

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        for (self.fields) |field| {
            if (field.len != 0) allocator.free(field);
        }
        allocator.free(self.fields);
        self.* = .{ .fields = &.{} };
    }
};

pub const Table = struct {
    rows: []Row,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        self.* = .{ .rows = &.{} };
    }
};

pub const HeaderIndex = struct {
    names: []const []const u8,
    lookup: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *HeaderIndex, allocator: std.mem.Allocator) void {
        self.lookup.deinit(allocator);
        for (self.names) |name| {
            if (name.len != 0) allocator.free(name);
        }
        allocator.free(self.names);
        self.* = .{ .names = &.{} };
    }

    pub fn indexOf(self: HeaderIndex, name: []const u8) ?usize {
        if (self.lookup.size > 0) return self.lookup.get(name);
        for (self.names, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, name)) return index;
        }
        return null;
    }

    pub fn field(self: HeaderIndex, row: Row, name: []const u8) ParseError![]const u8 {
        const index = self.indexOf(name) orelse return error.UnknownColumn;
        if (index >= row.fields.len) return error.RaggedRow;
        return row.fields[index];
    }
};

pub const HeaderTable = struct {
    headers: HeaderIndex,
    rows: []Row,

    pub fn deinit(self: *HeaderTable, allocator: std.mem.Allocator) void {
        self.headers.deinit(allocator);
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
        self.* = .{
            .headers = .{ .names = &.{} },
            .rows = &.{},
        };
    }
};

pub const BorrowedHeaderIndex = struct {
    names: []const []const u8,
    lookup: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *BorrowedHeaderIndex, allocator: std.mem.Allocator) void {
        self.lookup.deinit(allocator);
        allocator.free(self.names);
        self.* = .{ .names = &.{} };
    }

    pub fn indexOf(self: BorrowedHeaderIndex, name: []const u8) ?usize {
        if (self.lookup.size > 0) return self.lookup.get(name);
        for (self.names, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, name)) return index;
        }
        return null;
    }

    pub fn field(self: BorrowedHeaderIndex, row: BorrowedRowView, name: []const u8) ParseError![]const u8 {
        const index = self.indexOf(name) orelse return error.UnknownColumn;
        return row.field(index);
    }
};

pub const BorrowedHeaderTable = struct {
    headers: BorrowedHeaderIndex,
    table: BorrowedTable,
    first_data_row: usize = 1,

    pub fn deinit(self: *BorrowedHeaderTable, allocator: std.mem.Allocator) void {
        self.headers.deinit(allocator);
        self.table.deinit(allocator);
        self.* = .{
            .headers = .{ .names = &.{} },
            .table = .{
                .source = &.{},
                .rows = &.{},
                .fields = &.{},
                .quote_arena = &.{},
            },
            .first_data_row = 1,
        };
    }

    pub fn len(self: BorrowedHeaderTable) usize {
        if (self.table.rows.len <= self.first_data_row) return 0;
        return self.table.rows.len - self.first_data_row;
    }

    pub fn row(self: *const BorrowedHeaderTable, row_index: usize) ParseError!BorrowedRowView {
        if (row_index >= self.len()) return error.RaggedRow;
        return self.table.row(self.first_data_row + row_index);
    }

    pub fn field(self: *const BorrowedHeaderTable, row_index: usize, name: []const u8) ParseError![]const u8 {
        return self.headers.field(try self.row(row_index), name);
    }
};

pub const ArenaTable = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row,

    pub fn deinit(self: *ArenaTable) void {
        self.arena.deinit();
        self.rows = &.{};
    }
};

pub const BorrowedIndex = u32;

pub const BorrowedField = struct {
    start: BorrowedIndex,
    len: BorrowedIndex,
    realized: bool = false,
};

pub const BorrowedRow = struct {
    byte_offset: BorrowedIndex,
    fields_start: BorrowedIndex,
    field_count: BorrowedIndex,
};

pub const BorrowedRowView = struct {
    table: *const BorrowedTable,
    index: usize,

    pub fn len(self: BorrowedRowView) usize {
        return @intCast(self.table.rows[self.index].field_count);
    }

    pub fn field(self: BorrowedRowView, column_index: usize) ParseError![]const u8 {
        return self.table.field(self.index, column_index);
    }

    pub fn fieldByName(self: BorrowedRowView, headers: BorrowedHeaderIndex, name: []const u8) ParseError![]const u8 {
        return headers.field(self, name);
    }
};

pub const BorrowedTable = struct {
    source: []const u8,
    rows: []BorrowedRow,
    fields: []BorrowedField,
    quote_arena: []u8,

    pub fn deinit(self: *BorrowedTable, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        allocator.free(self.fields);
        allocator.free(self.quote_arena);
        self.* = .{
            .source = &.{},
            .rows = &.{},
            .fields = &.{},
            .quote_arena = &.{},
        };
    }

    pub fn row(self: *const BorrowedTable, row_index: usize) ParseError!BorrowedRowView {
        if (row_index >= self.rows.len) return error.RaggedRow;
        return .{ .table = self, .index = row_index };
    }

    pub fn field(self: *const BorrowedTable, row_index: usize, column_index: usize) ParseError![]const u8 {
        if (row_index >= self.rows.len) return error.RaggedRow;
        const row_meta = self.rows[row_index];
        if (column_index >= row_meta.field_count) return error.RaggedRow;
        const fields_start: usize = @intCast(row_meta.fields_start);
        const field_meta = self.fields[fields_start + column_index];
        return self.fieldFromMeta(field_meta);
    }

    fn fieldFromMeta(self: *const BorrowedTable, field_meta: BorrowedField) []const u8 {
        const start: usize = @intCast(field_meta.start);
        const len: usize = @intCast(field_meta.len);
        if (field_meta.realized) {
            return self.quote_arena[start..][0..len];
        }
        return self.source[start..][0..len];
    }
};

/// Borrowed row view emitted by StreamingBorrowedParser.
/// Field slices are valid only until the row callback returns.
pub const StreamingBorrowedRow = struct {
    source: []const u8,
    fields: []const BorrowedField,
    quote_arena: []const u8,

    pub fn len(self: StreamingBorrowedRow) usize {
        return self.fields.len;
    }

    pub fn field(self: StreamingBorrowedRow, column_index: usize) ParseError![]const u8 {
        if (column_index >= self.fields.len) return error.RaggedRow;
        return self.fieldFromMeta(self.fields[column_index]);
    }

    fn fieldFromMeta(self: StreamingBorrowedRow, field_meta: BorrowedField) []const u8 {
        const start: usize = @intCast(field_meta.start);
        const field_len: usize = @intCast(field_meta.len);
        if (field_meta.realized) {
            return self.quote_arena[start..][0..field_len];
        }
        return self.source[start..][0..field_len];
    }
};

pub const MappedInput = struct {
    data: []align(std.heap.page_size_min) const u8,

    pub fn deinit(self: *MappedInput) void {
        if (self.data.len != 0) std.posix.munmap(self.data);
    }
};

pub const StreamingParser = struct {
    allocator: std.mem.Allocator,
    options: ParseOptions,
    fields: std.ArrayList([]const u8) = .empty,
    field: std.ArrayList(u8) = .empty,
    in_quotes: bool = false,
    quote_closed: bool = false,
    field_started: bool = false,
    field_quoted: bool = false,
    pending_quote: bool = false,
    ignore_next_lf: bool = false,
    skip_comment_row: bool = false,
    last_was_delimiter: bool = false,
    seen_input: bool = false,
    row_index: usize = 0,
    column_index: usize = 0,
    byte_offset: usize = 0,
    line_index: usize = 0,
    line_column_index: usize = 0,
    expected_fields: ?usize = null,
    diagnostic: ?ParseDiagnostic = null,

    pub fn init(allocator: std.mem.Allocator, options: ParseOptions) ParseError!StreamingParser {
        try validateParseOptions(options);
        return .{
            .allocator = allocator,
            .options = options,
            .expected_fields = options.expected_fields,
        };
    }

    pub fn deinit(self: *StreamingParser) void {
        self.field.deinit(self.allocator);
        for (self.fields.items) |field| {
            if (field.len != 0) self.allocator.free(field);
        }
        self.fields.deinit(self.allocator);
    }

    pub fn feed(
        self: *StreamingParser,
        chunk: []const u8,
        comptime Context: type,
        context: *Context,
        on_row: *const fn (*Context, Row) anyerror!void,
    ) anyerror!void {
        var index: usize = 0;
        if (!self.seen_input) {
            self.seen_input = true;
            if (self.options.allow_bom and startsWithUtf8Bom(chunk)) {
                index = 3;
                self.byte_offset = 3;
            }
        }

        while (index < chunk.len) {
            const byte = chunk[index];

            if (self.ignore_next_lf) {
                self.ignore_next_lf = false;
                if (byte == '\n') {
                    self.byte_offset += 1;
                    index += 1;
                    continue;
                }
            }

            if (self.skip_comment_row) {
                self.advanceByte(byte);
                index += 1;
                if (byte == '\n' or byte == '\r') {
                    self.skip_comment_row = false;
                    self.finishLogicalRow();
                    self.ignore_next_lf = byte == '\r';
                }
                continue;
            }

            if (self.column_index == 0 and !self.field_started and self.field.items.len == 0) {
                if (self.options.skip_empty_rows and isRowEnding(byte)) {
                    self.advanceByte(byte);
                    index += 1;
                    self.finishLogicalRow();
                    self.ignore_next_lf = byte == '\r';
                    continue;
                }
                if (self.options.comment) |comment| {
                    if (byte == comment) {
                        self.skip_comment_row = true;
                        continue;
                    }
                }
            }

            if (self.pending_quote) {
                self.pending_quote = false;
                if (byte == self.options.quote) {
                    try self.field.append(self.allocator, self.options.quote);
                    self.advanceByte(byte);
                    index += 1;
                    continue;
                }
                self.in_quotes = false;
                self.quote_closed = true;
                continue;
            }

            if (self.in_quotes) {
                if (byte == self.options.quote) {
                    self.pending_quote = true;
                    self.advanceByte(byte);
                    index += 1;
                } else {
                    try self.field.append(self.allocator, byte);
                    self.advanceByte(byte);
                    index += 1;
                }
                continue;
            }

            if (self.quote_closed) {
                if (byte == self.options.delimiter) {
                    try self.finishField();
                    self.finishLogicalColumn();
                    self.quote_closed = false;
                    self.advanceByte(byte);
                    self.last_was_delimiter = true;
                    index += 1;
                } else if (isRowEnding(byte)) {
                    try self.finishField();
                    try self.emitRow(Context, context, on_row);
                    self.quote_closed = false;
                    self.advanceByte(byte);
                    self.ignore_next_lf = byte == '\r';
                    index += 1;
                } else if (self.options.tolerant) {
                    self.advanceByte(byte);
                    index += 1;
                } else {
                    self.setDiagnostic(.unexpected_byte_after_quote, "unexpected byte after closing quote");
                    return error.UnexpectedByteAfterQuote;
                }
                continue;
            }

            if (byte == self.options.delimiter) {
                try self.finishField();
                self.finishLogicalColumn();
                self.advanceByte(byte);
                self.last_was_delimiter = true;
                index += 1;
            } else if (isRowEnding(byte)) {
                try self.finishField();
                try self.emitRow(Context, context, on_row);
                self.advanceByte(byte);
                self.ignore_next_lf = byte == '\r';
                index += 1;
            } else if (byte == self.options.quote) {
                if (self.field_started or self.field.items.len != 0) {
                    if (!self.options.tolerant) {
                        self.setDiagnostic(.unexpected_quote, "unexpected quote in unquoted field");
                        return error.UnexpectedQuote;
                    }
                    try self.field.append(self.allocator, byte);
                } else {
                    self.in_quotes = true;
                    self.field_quoted = true;
                }
                self.field_started = true;
                self.last_was_delimiter = false;
                self.advanceByte(byte);
                index += 1;
            } else {
                try self.field.append(self.allocator, byte);
                self.field_started = true;
                self.last_was_delimiter = false;
                self.advanceByte(byte);
                index += 1;
            }
        }
    }

    pub fn finish(
        self: *StreamingParser,
        comptime Context: type,
        context: *Context,
        on_row: *const fn (*Context, Row) anyerror!void,
    ) anyerror!void {
        if (self.pending_quote) {
            self.pending_quote = false;
            self.in_quotes = false;
            self.quote_closed = true;
        }
        if (self.in_quotes) {
            self.setDiagnostic(.unterminated_quote, "unterminated quoted field");
            return error.UnterminatedQuote;
        }
        if (self.quote_closed or self.field_started or self.field.items.len != 0 or self.fields.items.len != 0 or self.last_was_delimiter) {
            try self.finishField();
            try self.emitRow(Context, context, on_row);
        }
    }

    fn finishField(self: *StreamingParser) ParseError!void {
        const trimmed = trimField(self.field.items, self.field_quoted, self.options);
        const owned_field: []const u8 = if (trimmed.len == 0) &.{} else try self.allocator.dupe(u8, trimmed);
        errdefer if (owned_field.len != 0) self.allocator.free(owned_field);

        try self.fields.append(self.allocator, owned_field);
        self.field.clearRetainingCapacity();
        self.field_started = false;
        self.field_quoted = false;
        self.last_was_delimiter = false;
    }

    fn emitRow(
        self: *StreamingParser,
        comptime Context: type,
        context: *Context,
        on_row: *const fn (*Context, Row) anyerror!void,
    ) anyerror!void {
        try self.applyRaggedPolicy();
        const owned_fields = try self.fields.toOwnedSlice(self.allocator);
        var row: Row = .{ .fields = owned_fields };
        defer row.deinit(self.allocator);

        try on_row(context, row);
        self.finishLogicalRow();
    }

    fn applyRaggedPolicy(self: *StreamingParser) ParseError!void {
        const expected = self.expected_fields orelse {
            if (self.options.ragged_row_policy != .allow) self.expected_fields = self.fields.items.len;
            return;
        };
        if (self.fields.items.len == expected) return;

        switch (self.options.ragged_row_policy) {
            .allow => {},
            .error_on_ragged => {
                self.setDiagnostic(.ragged_row, "row has an unexpected number of fields");
                return error.RaggedRow;
            },
            .pad => {
                while (self.fields.items.len < expected) try self.fields.append(self.allocator, &.{});
                if (self.fields.items.len > expected) {
                    self.freeFieldsFrom(expected);
                    self.fields.items.len = expected;
                }
            },
            .truncate => {
                if (self.fields.items.len > expected) {
                    self.freeFieldsFrom(expected);
                    self.fields.items.len = expected;
                }
            },
        }
    }

    fn freeFieldsFrom(self: *StreamingParser, start_index: usize) void {
        for (self.fields.items[start_index..]) |field| {
            if (field.len != 0) self.allocator.free(field);
        }
    }

    fn finishLogicalColumn(self: *StreamingParser) void {
        self.column_index += 1;
    }

    fn finishLogicalRow(self: *StreamingParser) void {
        self.row_index += 1;
        self.column_index = 0;
    }

    fn advanceByte(self: *StreamingParser, byte: u8) void {
        self.byte_offset += 1;
        if (!self.options.track_locations) return;

        if (byte == '\n' or byte == '\r') {
            self.line_index += 1;
            self.line_column_index = 0;
        } else {
            self.line_column_index += 1;
        }
    }

    fn currentLocation(self: StreamingParser) ParseLocation {
        return .{
            .row = self.row_index,
            .column = self.column_index,
            .byte_offset = self.byte_offset,
            .line = self.line_index,
            .line_column = self.line_column_index,
        };
    }

    fn setDiagnostic(self: *StreamingParser, code: ParseErrorCode, message: []const u8) void {
        self.diagnostic = .{
            .code = code,
            .location = self.currentLocation(),
            .message = message,
        };
    }
};

pub const StreamingBorrowedParser = struct {
    allocator: std.mem.Allocator,
    options: ParseOptions,
    backing: std.ArrayList(u8) = .empty,
    fields: std.ArrayList(BorrowedField) = .empty,
    quote_arena: std.ArrayList(u8) = .empty,
    expected_fields: ?usize = null,
    allow_bom: bool = true,
    active_source: []const u8 = &.{},
    consumed_byte_offset: usize = 0,
    emitted_rows: usize = 0,
    row_start_offset: usize = 0,
    diagnostic: ?ParseDiagnostic = null,

    pub fn init(allocator: std.mem.Allocator, options: ParseOptions) ParseError!StreamingBorrowedParser {
        try validateParseOptions(options);
        return .{
            .allocator = allocator,
            .options = options,
            .expected_fields = options.expected_fields,
            .allow_bom = options.allow_bom,
        };
    }

    pub fn deinit(self: *StreamingBorrowedParser) void {
        self.backing.deinit(self.allocator);
        self.fields.deinit(self.allocator);
        self.quote_arena.deinit(self.allocator);
    }

    pub fn feed(
        self: *StreamingBorrowedParser,
        chunk: []const u8,
        comptime Context: type,
        context: *Context,
        on_row: *const fn (*Context, StreamingBorrowedRow) anyerror!void,
    ) anyerror!void {
        if (chunk.len == 0) return;
        if (self.backing.items.len == 0) {
            if (completeRowPrefixLen(chunk, self.options, false)) |prefix_len| {
                if (prefix_len != 0) {
                    try self.emitRowsFromSource(chunk[0..prefix_len], Context, context, on_row);
                    self.allow_bom = false;
                    self.consumed_byte_offset += prefix_len;
                }
                if (prefix_len < chunk.len) try self.backing.appendSlice(self.allocator, chunk[prefix_len..]);
                return;
            }
        }
        try self.backing.appendSlice(self.allocator, chunk);
        try self.emitCompleteRows(false, Context, context, on_row);
    }

    pub fn finish(
        self: *StreamingBorrowedParser,
        comptime Context: type,
        context: *Context,
        on_row: *const fn (*Context, StreamingBorrowedRow) anyerror!void,
    ) anyerror!void {
        try self.emitCompleteRows(true, Context, context, on_row);
        if (self.backing.items.len != 0) {
            self.setDiagnostic(.unterminated_quote, emptyLocation(), "unterminated quoted field");
            return error.UnterminatedQuote;
        }
    }

    fn emitCompleteRows(
        self: *StreamingBorrowedParser,
        finish_input: bool,
        comptime Context: type,
        context: *Context,
        on_row: *const fn (*Context, StreamingBorrowedRow) anyerror!void,
    ) anyerror!void {
        const prefix_len = if (finish_input)
            self.backing.items.len
        else
            completeRowPrefixLen(self.backing.items, self.options, false) orelse return;

        if (prefix_len == 0) return;

        try self.emitRowsFromSource(self.backing.items[0..prefix_len], Context, context, on_row);
        self.allow_bom = false;
        self.discardPrefix(prefix_len);
    }

    fn emitRowsFromSource(
        self: *StreamingBorrowedParser,
        source: []const u8,
        comptime Context: type,
        context: *Context,
        on_row: *const fn (*Context, StreamingBorrowedRow) anyerror!void,
    ) anyerror!void {
        self.active_source = source;
        defer self.active_source = &.{};

        var parse_options = self.options;
        parse_options.allow_bom = self.allow_bom;
        var iterator = try FieldIterator.init(source, parse_options);
        while (true) {
            const maybe_field = iterator.next() catch |err| {
                self.setDiagnosticFromIterator(iterator, err);
                return err;
            };
            const field = maybe_field orelse break;
            try self.appendField(field);
            if (field.row_end) try self.emitRow(Context, context, on_row);
        }
    }

    fn appendField(self: *StreamingBorrowedParser, field: FieldSlice) ParseError!void {
        if (self.fields.items.len == 0) self.row_start_offset = field.location.byte_offset;
        if (self.options.max_row_bytes) |max_row_bytes| {
            if (field.location.byte_offset >= self.row_start_offset and field.location.byte_offset - self.row_start_offset > max_row_bytes) {
                self.setDiagnostic(.row_too_large, field.location, "row exceeds configured byte limit");
                return error.RowTooLarge;
            }
        }

        const field_meta = if (field.data.len == 0)
            BorrowedField{ .start = 0, .len = 0 }
        else if (field.needs_unescape)
            try self.appendUnescapedQuotedField(field.data, field.location)
        else
            BorrowedField{
                .start = try self.sourceOffset(field.data, field.location),
                .len = try self.compactIndex(field.data.len, field.location),
            };

        try self.fields.append(self.allocator, field_meta);
    }

    fn emitRow(
        self: *StreamingBorrowedParser,
        comptime Context: type,
        context: *Context,
        on_row: *const fn (*Context, StreamingBorrowedRow) anyerror!void,
    ) anyerror!void {
        try self.applyRaggedPolicy(emptyLocation());
        const row: StreamingBorrowedRow = .{
            .source = self.active_source,
            .fields = self.fields.items,
            .quote_arena = self.quote_arena.items,
        };
        try on_row(context, row);

        self.fields.clearRetainingCapacity();
        self.quote_arena.clearRetainingCapacity();
        self.row_start_offset = 0;
        self.emitted_rows += 1;
    }

    fn applyRaggedPolicy(self: *StreamingBorrowedParser, location: ParseLocation) ParseError!void {
        const expected = self.expected_fields orelse {
            if (self.options.ragged_row_policy != .allow) self.expected_fields = self.fields.items.len;
            return;
        };

        if (self.fields.items.len == expected) return;

        switch (self.options.ragged_row_policy) {
            .allow => {},
            .error_on_ragged => {
                self.setDiagnostic(.ragged_row, location, "row has an unexpected number of fields");
                return error.RaggedRow;
            },
            .pad => {
                while (self.fields.items.len < expected) {
                    try self.fields.append(self.allocator, .{ .start = 0, .len = 0 });
                }
                if (self.fields.items.len > expected) {
                    self.fields.items.len = expected;
                }
            },
            .truncate => {
                if (self.fields.items.len > expected) {
                    self.fields.items.len = expected;
                }
            },
        }
    }

    fn appendUnescapedQuotedField(self: *StreamingBorrowedParser, field: []const u8, location: ParseLocation) ParseError!BorrowedField {
        const start = try self.compactIndex(self.quote_arena.items.len, location);
        const max_index: usize = std.math.maxInt(BorrowedIndex);
        if (field.len > max_index or self.quote_arena.items.len > max_index - field.len) {
            self.setDiagnostic(.input_too_large, location, "quote arena exceeds borrowed row compact index range");
            return error.InputTooLarge;
        }

        try self.quote_arena.ensureUnusedCapacity(self.allocator, field.len);
        const start_offset = self.quote_arena.items.len;
        self.quote_arena.items.len += field.len;

        var read_index: usize = 0;
        var write_index = start_offset;
        while (read_index < field.len) {
            if (field[read_index] == self.options.quote and read_index + 1 < field.len and field[read_index + 1] == self.options.quote) {
                self.quote_arena.items[write_index] = self.options.quote;
                write_index += 1;
                read_index += 2;
            } else {
                self.quote_arena.items[write_index] = field[read_index];
                write_index += 1;
                read_index += 1;
            }
        }
        self.quote_arena.items.len = write_index;

        return .{
            .start = start,
            .len = try self.compactIndex(self.quote_arena.items.len - start_offset, location),
            .realized = true,
        };
    }

    fn sourceOffset(self: *StreamingBorrowedParser, field: []const u8, location: ParseLocation) ParseError!BorrowedIndex {
        const base = @intFromPtr(self.active_source.ptr);
        const ptr = @intFromPtr(field.ptr);
        if (ptr < base or ptr > base + self.active_source.len) {
            self.setDiagnostic(.input_too_large, location, "field does not point into streaming backing storage");
            return error.InputTooLarge;
        }
        return self.compactIndex(ptr - base, location);
    }

    fn compactIndex(self: *StreamingBorrowedParser, value: usize, location: ParseLocation) ParseError!BorrowedIndex {
        return compactBorrowedIndex(value) catch |err| {
            self.setDiagnostic(.input_too_large, location, "streaming borrowed row exceeds compact index range");
            return err;
        };
    }

    fn discardPrefix(self: *StreamingBorrowedParser, prefix_len: usize) void {
        const remaining_len = self.backing.items.len - prefix_len;
        if (remaining_len != 0) {
            std.mem.copyForwards(u8, self.backing.items[0..remaining_len], self.backing.items[prefix_len..]);
        }
        self.backing.items.len = remaining_len;
        self.consumed_byte_offset += prefix_len;
    }

    fn setDiagnosticFromIterator(self: *StreamingBorrowedParser, iterator: FieldIterator, err: ParseError) void {
        self.setDiagnosticFromDiagnostic(
            iterator.diagnostic orelse diagnosticForError(err, iterator.currentLocation()),
        );
    }

    fn setDiagnostic(self: *StreamingBorrowedParser, code: ParseErrorCode, location: ParseLocation, message: []const u8) void {
        var translated = location;
        translated.row += self.emitted_rows;
        translated.byte_offset += self.consumed_byte_offset;
        self.diagnostic = .{
            .code = code,
            .location = translated,
            .message = message,
        };
    }

    fn setDiagnosticFromDiagnostic(self: *StreamingBorrowedParser, diagnostic: ParseDiagnostic) void {
        self.setDiagnostic(diagnostic.code, diagnostic.location, diagnostic.message);
    }
};

pub const FieldIterator = struct {
    input: []const u8,
    options: ParseOptions,
    byte_index: usize = 0,
    row_index: usize = 0,
    column_index: usize = 0,
    line_index: usize = 0,
    line_column_index: usize = 0,
    pending_final_empty_field: bool = false,
    diagnostic: ?ParseDiagnostic = null,

    pub fn init(input: []const u8, options: ParseOptions) ParseError!FieldIterator {
        try validateParseOptions(options);
        const start_index: usize = if (options.allow_bom and startsWithUtf8Bom(input)) 3 else 0;
        return .{
            .input = input,
            .options = options,
            .byte_index = start_index,
        };
    }

    pub fn next(self: *FieldIterator) ParseError!?FieldSlice {
        while (true) {
            if (self.pending_final_empty_field) {
                self.pending_final_empty_field = false;
                const location = self.currentLocation();
                self.finishLogicalField(true);
                return .{
                    .data = &.{},
                    .row_end = true,
                    .quoted = false,
                    .needs_unescape = false,
                    .location = location,
                };
            }

            if (self.byte_index >= self.input.len) return null;

            if (self.options.skip_empty_rows and self.column_index == 0 and isRowEnding(self.input[self.byte_index])) {
                self.advanceTo(consumeRowEnding(self.input, self.byte_index), true);
                continue;
            }

            if (self.options.comment) |comment| {
                if (self.column_index == 0 and self.input[self.byte_index] == comment) {
                    self.skipCommentRow();
                    continue;
                }
            }

            break;
        }

        if (self.input[self.byte_index] == self.options.quote) {
            return try self.nextQuoted();
        }
        return try self.nextUnquoted();
    }

    fn nextQuoted(self: *FieldIterator) ParseError!FieldSlice {
        const location = self.currentLocation();
        const field_start = self.byte_index + 1;
        var scan_index = field_start;
        var needs_unescape = false;

        while (findScalarStructuralPos(self.input, scan_index, self.options.quote)) |quote_index| {
            if (quote_index + 1 < self.input.len and self.input[quote_index + 1] == self.options.quote) {
                needs_unescape = true;
                scan_index = quote_index + 2;
                continue;
            }

            const data = trimField(self.input[field_start..quote_index], true, self.options);
            const after_quote_index = quote_index + 1;

            if (after_quote_index >= self.input.len) {
                self.advanceTo(after_quote_index, true);
                return .{
                    .data = data,
                    .row_end = true,
                    .quoted = true,
                    .needs_unescape = needs_unescape,
                    .location = location,
                };
            }

            const terminator = self.input[after_quote_index];
            if (terminator == self.options.delimiter) {
                self.advanceTo(after_quote_index + 1, false);
                self.pending_final_empty_field = self.byte_index == self.input.len;
                return .{
                    .data = data,
                    .row_end = false,
                    .quoted = true,
                    .needs_unescape = needs_unescape,
                    .location = location,
                };
            }

            if (isRowEnding(terminator)) {
                self.advanceTo(consumeRowEnding(self.input, after_quote_index), true);
                return .{
                    .data = data,
                    .row_end = true,
                    .quoted = true,
                    .needs_unescape = needs_unescape,
                    .location = location,
                };
            }

            if (self.options.tolerant) {
                const terminator_index = self.findNextTerminator(after_quote_index) orelse self.input.len;
                if (terminator_index >= self.input.len) {
                    self.advanceTo(terminator_index, true);
                    return .{
                        .data = data,
                        .row_end = true,
                        .quoted = true,
                        .needs_unescape = needs_unescape,
                        .location = location,
                    };
                }

                const tolerant_terminator = self.input[terminator_index];
                const row_end = isRowEnding(tolerant_terminator);
                self.advanceTo(if (row_end) consumeRowEnding(self.input, terminator_index) else terminator_index + 1, row_end);
                self.pending_final_empty_field = !row_end and self.byte_index == self.input.len;
                return .{
                    .data = data,
                    .row_end = row_end,
                    .quoted = true,
                    .needs_unescape = needs_unescape,
                    .location = location,
                };
            }

            self.setDiagnostic(.unexpected_byte_after_quote, self.locationAtOffset(after_quote_index), "unexpected byte after closing quote");
            return error.UnexpectedByteAfterQuote;
        }

        self.setDiagnostic(.unterminated_quote, location, "unterminated quoted field");
        return error.UnterminatedQuote;
    }

    fn nextUnquoted(self: *FieldIterator) ParseError!FieldSlice {
        const location = self.currentLocation();
        const field_start = self.byte_index;
        var scan_index = field_start;
        while (findFieldStructuralPos(self.input, scan_index, self.options.delimiter, self.options.quote)) |special_index| {
            const byte = self.input[special_index];

            if (byte == self.options.quote) {
                if (self.options.tolerant) {
                    scan_index = special_index + 1;
                    continue;
                }

                self.setDiagnostic(.unexpected_quote, self.locationAtOffset(special_index), "unexpected quote in unquoted field");
                return error.UnexpectedQuote;
            }

            if (byte == self.options.delimiter) {
                self.advanceTo(special_index + 1, false);
                self.pending_final_empty_field = self.byte_index == self.input.len;
                return .{
                    .data = trimField(self.input[field_start..special_index], false, self.options),
                    .row_end = false,
                    .quoted = false,
                    .needs_unescape = false,
                    .location = location,
                };
            }

            if (isRowEnding(byte)) {
                self.advanceTo(consumeRowEnding(self.input, special_index), true);
                return .{
                    .data = trimField(self.input[field_start..special_index], false, self.options),
                    .row_end = true,
                    .quoted = false,
                    .needs_unescape = false,
                    .location = location,
                };
            }
        }

        self.advanceTo(self.input.len, true);
        return .{
            .data = trimField(self.input[field_start..], false, self.options),
            .row_end = true,
            .quoted = false,
            .needs_unescape = false,
            .location = location,
        };
    }

    fn currentLocation(self: FieldIterator) ParseLocation {
        return .{
            .row = self.row_index,
            .column = self.column_index,
            .byte_offset = self.byte_index,
            .line = self.line_index,
            .line_column = self.line_column_index,
        };
    }

    fn locationAtOffset(self: FieldIterator, byte_offset: usize) ParseLocation {
        var line_index = self.line_index;
        var line_column_index = self.line_column_index;
        if (self.options.track_locations) {
            updatePhysicalPosition(self.input[self.byte_index..byte_offset], &line_index, &line_column_index);
        }
        return .{
            .row = self.row_index,
            .column = self.column_index,
            .byte_offset = byte_offset,
            .line = line_index,
            .line_column = line_column_index,
        };
    }

    fn advanceTo(self: *FieldIterator, new_byte_index: usize, row_end: bool) void {
        if (self.options.track_locations) {
            updatePhysicalPosition(self.input[self.byte_index..new_byte_index], &self.line_index, &self.line_column_index);
        }
        self.byte_index = new_byte_index;
        self.finishLogicalField(row_end);
    }

    fn finishLogicalField(self: *FieldIterator, row_end: bool) void {
        if (row_end) {
            self.row_index += 1;
            self.column_index = 0;
        } else {
            self.column_index += 1;
        }
    }

    fn findNextTerminator(self: FieldIterator, start_index: usize) ?usize {
        return findTerminatorStructuralPos(self.input, start_index, self.options.delimiter);
    }

    fn skipCommentRow(self: *FieldIterator) void {
        const terminators = [_]u8{ '\n', '\r' };
        const row_end_index = std.mem.findAnyPos(u8, self.input, self.byte_index, &terminators) orelse {
            if (self.options.track_locations) {
                updatePhysicalPosition(self.input[self.byte_index..], &self.line_index, &self.line_column_index);
            }
            self.byte_index = self.input.len;
            self.row_index += 1;
            self.column_index = 0;
            return;
        };
        self.advanceTo(consumeRowEnding(self.input, row_end_index), true);
    }

    fn setDiagnostic(self: *FieldIterator, code: ParseErrorCode, location: ParseLocation, message: []const u8) void {
        self.diagnostic = .{
            .code = code,
            .location = location,
            .message = message,
        };
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) ParseError!Table {
    return parseWithDiagnostic(allocator, input, options, null);
}

pub fn parseWithDiagnostic(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
    diagnostic: ?*ParseDiagnostic,
) ParseError!Table {
    var parse_options = options;
    if (diagnostic != null) parse_options.track_locations = true;

    if (diagnostic) |out| out.* = .{
        .code = .invalid_options,
        .location = emptyLocation(),
        .message = "",
    };

    var parser: Parser = .{
        .allocator = allocator,
        .options = parse_options,
        .diagnostic = diagnostic,
        .expected_fields = parse_options.expected_fields,
    };
    errdefer parser.deinit();

    var iterator = try FieldIterator.init(input, parse_options);
    while (true) {
        const maybe_field = iterator.next() catch |err| {
            if (diagnostic) |out| out.* = iterator.diagnostic orelse diagnosticForError(err, iterator.currentLocation());
            return err;
        };
        const field = maybe_field orelse break;
        try parser.appendField(field);
        if (field.row_end) try parser.finishRow(field.location);
    }

    return .{ .rows = try parser.rows.toOwnedSlice(allocator) };
}

pub fn parseArena(backing_allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) ParseError!ArenaTable {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();

    const table = try parse(arena.allocator(), input, options);
    return .{
        .arena = arena,
        .rows = table.rows,
    };
}

pub fn parseBorrowed(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) ParseError!BorrowedTable {
    return parseBorrowedWithDiagnostic(allocator, input, options, null);
}

pub fn parseBorrowedParallel(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
    parallel_options: ParallelParseOptions,
) anyerror!BorrowedTable {
    const worker_count = try effectiveWorkerCount(input.len, parallel_options);
    if (worker_count <= 1) return parseBorrowed(allocator, input, options);

    const chunks = try buildParallelChunks(allocator, input, options, parallel_options.min_chunk_bytes, worker_count);
    defer allocator.free(chunks);
    if (chunks.len <= 1) return parseBorrowed(allocator, input, options);

    var results = try allocator.alloc(ParallelChunkResult, chunks.len);
    defer allocator.free(results);
    for (results) |*result| result.* = .{};
    errdefer deinitParallelChunkResults(results);

    var chunk_options = options;
    if (options.expected_fields == null and options.ragged_row_policy != .allow) {
        var first_options = options;
        first_options.allow_bom = chunks[0].start == 0 and options.allow_bom;
        results[0].table = parseBorrowed(std.heap.smp_allocator, input[chunks[0].start..chunks[0].end], first_options) catch |err| {
            results[0].err = err;
            return err;
        };
        if (results[0].table.?.rows.len != 0) {
            chunk_options.expected_fields = @intCast(results[0].table.?.rows[0].field_count);
        }
    }

    var threads = try allocator.alloc(std.Thread, chunks.len);
    defer allocator.free(threads);
    var spawned_count: usize = 0;

    for (chunks, 0..) |chunk, chunk_index| {
        if (results[chunk_index].table != null) continue;
        var parse_options = chunk_options;
        parse_options.allow_bom = chunk.start == 0 and options.allow_bom;
        const thread = std.Thread.spawn(.{}, parseBorrowedParallelWorker, .{
            &results[chunk_index],
            input[chunk.start..chunk.end],
            parse_options,
        }) catch |err| {
            for (threads[0..spawned_count]) |spawned| spawned.join();
            return err;
        };
        threads[spawned_count] = thread;
        spawned_count += 1;
    }

    for (threads[0..spawned_count]) |thread| thread.join();

    for (results) |result| {
        if (result.err) |err| return err;
    }

    return try mergeParallelBorrowedTables(allocator, input, chunks, results);
}

pub fn parseBorrowedWithDiagnostic(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
    diagnostic: ?*ParseDiagnostic,
) ParseError!BorrowedTable {
    var parse_options = options;
    if (diagnostic != null) parse_options.track_locations = true;

    if (diagnostic) |out| out.* = .{
        .code = .invalid_options,
        .location = emptyLocation(),
        .message = "",
    };

    if (input.len > std.math.maxInt(BorrowedIndex)) {
        if (diagnostic) |out| out.* = .{
            .code = .input_too_large,
            .location = emptyLocation(),
            .message = "input exceeds borrowed table compact index range",
        };
        return error.InputTooLarge;
    }

    if (diagnostic == null and canUseFastBorrowedPath(parse_options)) {
        if (parse_options.allow_bom) {
            return parseBorrowedFast(.{}, allocator, input);
        }
        return parseBorrowedFast(.{ .allow_bom = false }, allocator, input);
    }

    var parser: BorrowedParser = .{
        .allocator = allocator,
        .input = input,
        .options = parse_options,
        .diagnostic = diagnostic,
        .expected_fields = parse_options.expected_fields,
    };
    errdefer parser.deinit();

    var iterator = try FieldIterator.init(input, parse_options);
    while (true) {
        const maybe_field = iterator.next() catch |err| {
            if (diagnostic) |out| out.* = iterator.diagnostic orelse diagnosticForError(err, iterator.currentLocation());
            return err;
        };
        const field = maybe_field orelse break;
        try parser.appendField(field);
        if (field.row_end) try parser.finishRow(field.location);
    }

    return try parser.toOwnedTable();
}

fn canUseFastBorrowedPath(options: ParseOptions) bool {
    return options.delimiter == ',' and
        options.quote == '"' and
        options.trim == .none and
        options.comment == null and
        !options.tolerant and
        !options.skip_empty_rows and
        options.ragged_row_policy == .allow and
        options.expected_fields == null and
        options.max_row_bytes == null and
        !options.track_locations;
}

pub fn parseBorrowedFast(comptime fast_options: FastFieldOptions, allocator: std.mem.Allocator, input: []const u8) ParseError!BorrowedTable {
    comptime validateFastFieldOptions(fast_options);

    if (input.len > std.math.maxInt(BorrowedIndex)) return error.InputTooLarge;

    var parser: FastBorrowedParser = .{
        .allocator = allocator,
        .input = input,
        .quote = fast_options.quote,
    };
    errdefer parser.deinit();

    var iterator = FastFieldIterator(fast_options).init(input);
    while (try iterator.next()) |field| {
        try parser.appendField(field);
        if (field.row_end) try parser.finishRow(field.location);
    }

    return try parser.toOwnedTable();
}

pub fn mapFile(file: std.Io.File, io: std.Io) !MappedInput {
    const size: usize = @intCast((try file.stat(io)).size);
    if (size == 0) return .{ .data = &.{} };
    const mapped = try std.posix.mmap(
        null,
        size,
        readOnlyProt(),
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    return .{ .data = mapped };
}

pub fn parseMapped(allocator: std.mem.Allocator, mapped: MappedInput, options: ParseOptions) ParseError!Table {
    return parse(allocator, mapped.data, options);
}

pub fn parseFileChunks(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    options: ParseOptions,
    chunk_size: usize,
    comptime Context: type,
    context: *Context,
    on_row: *const fn (*Context, Row) anyerror!void,
) anyerror!void {
    if (chunk_size == 0) return error.InvalidOptions;

    const buffer = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buffer);

    var parser = try StreamingParser.init(allocator, options);
    defer parser.deinit();

    while (true) {
        const read_count = file.readStreaming(io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try parser.feed(buffer[0..read_count], Context, context, on_row);
    }

    try parser.finish(Context, context, on_row);
}

pub fn parseBorrowedFileChunks(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    options: ParseOptions,
    chunk_size: usize,
    comptime Context: type,
    context: *Context,
    on_row: *const fn (*Context, StreamingBorrowedRow) anyerror!void,
) anyerror!void {
    if (chunk_size == 0) return error.InvalidOptions;

    const buffer = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buffer);

    var parser = try StreamingBorrowedParser.init(allocator, options);
    defer parser.deinit();

    while (true) {
        const read_count = file.readStreaming(io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try parser.feed(buffer[0..read_count], Context, context, on_row);
    }

    try parser.finish(Context, context, on_row);
}

pub fn buildHeaderIndex(allocator: std.mem.Allocator, header: Row) ParseError!HeaderIndex {
    var names: std.ArrayList([]const u8) = .empty;
    var lookup: std.StringHashMapUnmanaged(usize) = .empty;
    errdefer {
        lookup.deinit(allocator);
        for (names.items) |name| {
            if (name.len != 0) allocator.free(name);
        }
        names.deinit(allocator);
    }

    for (header.fields) |name| {
        if (lookup.get(name) != null) return error.DuplicateHeader;
        const owned_name: []const u8 = if (name.len == 0) &.{} else try allocator.dupe(u8, name);
        errdefer if (owned_name.len != 0) allocator.free(owned_name);
        try lookup.putNoClobber(allocator, owned_name, names.items.len);
        try names.append(allocator, owned_name);
    }

    return .{
        .names = try names.toOwnedSlice(allocator),
        .lookup = lookup,
    };
}

pub fn buildBorrowedHeaderIndex(allocator: std.mem.Allocator, table: *const BorrowedTable) ParseError!BorrowedHeaderIndex {
    if (table.rows.len == 0) return error.MissingHeader;

    const header = try table.row(0);
    var names: std.ArrayList([]const u8) = .empty;
    var lookup: std.StringHashMapUnmanaged(usize) = .empty;
    errdefer {
        lookup.deinit(allocator);
        names.deinit(allocator);
    }

    for (0..header.len()) |column_index| {
        const name = try header.field(column_index);
        if (lookup.get(name) != null) return error.DuplicateHeader;
        try lookup.putNoClobber(allocator, name, column_index);
        try names.append(allocator, name);
    }

    return .{
        .names = try names.toOwnedSlice(allocator),
        .lookup = lookup,
    };
}

pub fn parseWithHeader(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) ParseError!HeaderTable {
    var table = try parse(allocator, input, options);
    errdefer table.deinit(allocator);

    if (table.rows.len == 0) return error.MissingHeader;
    var headers = try buildHeaderIndex(allocator, table.rows[0]);
    errdefer headers.deinit(allocator);

    const data_rows = try allocator.alloc(Row, table.rows.len - 1);
    errdefer allocator.free(data_rows);
    @memcpy(data_rows, table.rows[1..]);

    table.rows[0].deinit(allocator);
    allocator.free(table.rows);
    table.rows = &.{};

    return .{
        .headers = headers,
        .rows = data_rows,
    };
}

pub fn parseBorrowedWithHeader(allocator: std.mem.Allocator, input: []const u8, options: ParseOptions) ParseError!BorrowedHeaderTable {
    var table = try parseBorrowed(allocator, input, options);
    errdefer table.deinit(allocator);

    var headers = try buildBorrowedHeaderIndex(allocator, &table);
    errdefer headers.deinit(allocator);

    return .{
        .headers = headers,
        .table = table,
    };
}

pub fn decodeRow(comptime T: type, headers: HeaderIndex, row: Row) DecodeError!T {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return error.UnsupportedSchemaType;

    var out: T = undefined;
    inline for (type_info.@"struct".fields) |field| {
        const raw = try headers.field(row, field.name);
        @field(out, field.name) = try decodeField(field.type, raw);
    }
    return out;
}

pub fn decodeBorrowedRow(comptime T: type, headers: BorrowedHeaderIndex, row: BorrowedRowView) DecodeError!T {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return error.UnsupportedSchemaType;

    var out: T = undefined;
    inline for (type_info.@"struct".fields) |field| {
        const raw = try row.fieldByName(headers, field.name);
        @field(out, field.name) = try decodeField(field.type, raw);
    }
    return out;
}

pub fn validateWriteOptions(options: WriteOptions) ParseError!void {
    if (options.delimiter == options.quote) return error.InvalidOptions;
    if (isRowEnding(options.delimiter) or isRowEnding(options.quote)) return error.InvalidOptions;
    if (options.line_ending.len == 0) return error.InvalidOptions;
    for (options.line_ending) |byte| {
        if (!isRowEnding(byte)) return error.InvalidOptions;
    }
}

pub fn writeRecord(writer: *std.Io.Writer, row: []const []const u8, options: WriteOptions) (std.Io.Writer.Error || ParseError)!void {
    try validateWriteOptions(options);
    for (row, 0..) |field, field_index| {
        if (field_index != 0) try writer.writeByte(options.delimiter);
        try writeField(writer, field, options);
    }
}

pub fn writeRows(writer: *std.Io.Writer, rows: []const Row, options: WriteOptions) (std.Io.Writer.Error || ParseError)!void {
    try validateWriteOptions(options);
    for (rows, 0..) |row, row_index| {
        if (row_index != 0) try writer.writeAll(options.line_ending);
        for (row.fields, 0..) |field, field_index| {
            if (field_index != 0) try writer.writeByte(options.delimiter);
            try writeField(writer, field, options);
        }
    }
    if (options.trailing_line_ending and rows.len != 0) try writer.writeAll(options.line_ending);
}

pub fn parseIntField(comptime T: type, field: []const u8, radix: u8) !T {
    return std.fmt.parseInt(T, field, radix);
}

pub fn parseFloatField(comptime T: type, field: []const u8) !T {
    return std.fmt.parseFloat(T, field);
}

fn decodeField(comptime T: type, field: []const u8) DecodeError!T {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .int => try std.fmt.parseInt(T, field, 10),
        .float => try std.fmt.parseFloat(T, field),
        .bool => try parseBoolField(field),
        .optional => |optional| if (field.len == 0) null else try decodeField(optional.child, field),
        .pointer => |pointer| blk: {
            if (pointer.size == .slice and pointer.child == u8 and pointer.is_const) break :blk field;
            return error.UnsupportedSchemaType;
        },
        else => error.UnsupportedSchemaType,
    };
}

fn parseBoolField(field: []const u8) error{InvalidBool}!bool {
    if (std.ascii.eqlIgnoreCase(field, "true") or std.mem.eql(u8, field, "1")) return true;
    if (std.ascii.eqlIgnoreCase(field, "false") or std.mem.eql(u8, field, "0")) return false;
    return error.InvalidBool;
}

pub fn countFieldsFast(comptime options: FastFieldOptions, input: []const u8) ParseError!usize {
    comptime validateFastFieldOptions(options);

    var counter = FastFieldCounter(options).init(input);
    return try counter.count();
}

fn writeField(writer: *std.Io.Writer, field: []const u8, options: WriteOptions) std.Io.Writer.Error!void {
    const must_quote = options.quote_empty and field.len == 0 or fieldNeedsQuoting(field, options);
    if (!must_quote) {
        try writer.writeAll(field);
        return;
    }

    try writer.writeByte(options.quote);
    for (field) |byte| {
        if (byte == options.quote) try writer.writeByte(options.quote);
        try writer.writeByte(byte);
    }
    try writer.writeByte(options.quote);
}

fn fieldNeedsQuoting(field: []const u8, options: WriteOptions) bool {
    for (field) |byte| {
        if (byte == options.delimiter or byte == options.quote or byte == '\n' or byte == '\r') return true;
    }
    return false;
}

fn isRowEnding(byte: u8) bool {
    return byte == '\n' or byte == '\r';
}

fn validateFastFieldOptions(comptime options: FastFieldOptions) void {
    if (options.delimiter == options.quote) @compileError("CSV delimiter and quote must differ");
    if (isRowEnding(options.delimiter) or isRowEnding(options.quote)) @compileError("CSV delimiter and quote must not be row endings");
}

fn consumeRowEnding(input: []const u8, byte_index: usize) usize {
    if (input[byte_index] == '\r' and byte_index + 1 < input.len and input[byte_index + 1] == '\n') {
        return byte_index + 2;
    }
    return byte_index + 1;
}

const structural_vector_lanes = 32;
const StructuralMask = std.meta.Int(.unsigned, structural_vector_lanes);

fn FastFieldCounter(comptime options: FastFieldOptions) type {
    return struct {
        input: []const u8,
        byte_index: usize,
        structural_mask: StructuralMask = 0,
        structural_offset: usize = 0,
        pending_final_empty_field: bool = false,

        const Self = @This();

        fn init(input: []const u8) Self {
            return .{
                .input = input,
                .byte_index = if (options.allow_bom and startsWithUtf8Bom(input)) 3 else 0,
            };
        }

        fn count(self: *Self) ParseError!usize {
            var field_count: usize = 0;

            while (true) {
                if (self.pending_final_empty_field) {
                    self.pending_final_empty_field = false;
                    field_count += 1;
                    continue;
                }
                if (self.byte_index >= self.input.len) break;

                field_count += 1;
                if (self.input[self.byte_index] == options.quote) {
                    try self.consumeQuoted();
                } else {
                    try self.consumeUnquoted();
                }
            }

            return field_count;
        }

        fn consumeQuoted(self: *Self) ParseError!void {
            var scan_index = self.byte_index + 1;

            while (findScalarStructuralPos(self.input, scan_index, options.quote)) |quote_index| {
                if (quote_index + 1 < self.input.len and self.input[quote_index + 1] == options.quote) {
                    scan_index = quote_index + 2;
                    continue;
                }

                const after_quote_index = quote_index + 1;
                if (after_quote_index >= self.input.len) {
                    self.byte_index = after_quote_index;
                    return;
                }

                const terminator = self.input[after_quote_index];
                if (terminator == options.delimiter) {
                    self.byte_index = after_quote_index + 1;
                    self.pending_final_empty_field = self.byte_index == self.input.len;
                    return;
                }

                if (isRowEnding(terminator)) {
                    self.byte_index = consumeRowEnding(self.input, after_quote_index);
                    return;
                }

                return error.UnexpectedByteAfterQuote;
            }

            return error.UnterminatedQuote;
        }

        fn consumeUnquoted(self: *Self) ParseError!void {
            var scan_index = self.byte_index;

            while (self.nextStructuralPos(scan_index)) |special_index| {
                const byte = self.input[special_index];
                if (byte == options.quote) return error.UnexpectedQuote;

                if (byte == options.delimiter) {
                    self.byte_index = special_index + 1;
                    self.pending_final_empty_field = self.byte_index == self.input.len;
                    return;
                }

                if (isRowEnding(byte)) {
                    self.byte_index = consumeRowEnding(self.input, special_index);
                    return;
                }

                scan_index = special_index + 1;
            }

            self.byte_index = self.input.len;
        }

        fn nextStructuralPos(self: *Self, start_index: usize) ?usize {
            while (self.structural_mask != 0) {
                const lane: usize = @intCast(@ctz(self.structural_mask));
                const byte_index = self.structural_offset + lane;
                self.structural_mask &= self.structural_mask -% 1;
                if (byte_index >= start_index) return byte_index;
            }

            var index = start_index;
            const delimiter_vector: @Vector(structural_vector_lanes, u8) = @splat(options.delimiter);
            const quote_vector: @Vector(structural_vector_lanes, u8) = @splat(options.quote);
            const lf_vector: @Vector(structural_vector_lanes, u8) = @splat('\n');
            const cr_vector: @Vector(structural_vector_lanes, u8) = @splat('\r');

            while (index + structural_vector_lanes <= self.input.len) : (index += structural_vector_lanes) {
                const bytes: @Vector(structural_vector_lanes, u8) = self.input[index..][0..structural_vector_lanes].*;
                const matches = (bytes == delimiter_vector) | (bytes == quote_vector) | (bytes == lf_vector) | (bytes == cr_vector);
                self.structural_mask = @bitCast(matches);
                if (self.structural_mask != 0) {
                    self.structural_offset = index;
                    const lane: usize = @intCast(@ctz(self.structural_mask));
                    self.structural_mask &= self.structural_mask -% 1;
                    return index + lane;
                }
            }

            while (index < self.input.len) : (index += 1) {
                const byte = self.input[index];
                if (byte == options.delimiter or byte == options.quote or byte == '\n' or byte == '\r') return index;
            }

            return null;
        }
    };
}

pub fn FastFieldIterator(comptime options: FastFieldOptions) type {
    return struct {
        input: []const u8,
        byte_index: usize,
        row_index: usize = 0,
        column_index: usize = 0,
        structural_mask: StructuralMask = 0,
        structural_offset: usize = 0,
        pending_final_empty_field: bool = false,

        const Self = @This();

        fn init(input: []const u8) Self {
            return .{
                .input = input,
                .byte_index = if (options.allow_bom and startsWithUtf8Bom(input)) 3 else 0,
            };
        }

        fn next(self: *Self) ParseError!?FieldSlice {
            if (self.pending_final_empty_field) {
                self.pending_final_empty_field = false;
                const location = self.currentLocation();
                self.finishLogicalField(true);
                return .{
                    .data = &.{},
                    .row_end = true,
                    .quoted = false,
                    .needs_unescape = false,
                    .location = location,
                };
            }
            if (self.byte_index >= self.input.len) return null;

            if (self.input[self.byte_index] == options.quote) {
                return try self.nextQuoted();
            }
            return try self.nextUnquoted();
        }

        fn nextQuoted(self: *Self) ParseError!FieldSlice {
            const location = self.currentLocation();
            const field_start = self.byte_index + 1;
            var scan_index = field_start;
            var needs_unescape = false;

            while (findScalarStructuralPos(self.input, scan_index, options.quote)) |special_index| {
                if (special_index + 1 < self.input.len and self.input[special_index + 1] == options.quote) {
                    needs_unescape = true;
                    scan_index = special_index + 2;
                    continue;
                }

                const data = self.input[field_start..special_index];
                const after_quote_index = special_index + 1;
                if (after_quote_index >= self.input.len) {
                    self.byte_index = after_quote_index;
                    self.finishLogicalField(true);
                    return .{
                        .data = data,
                        .row_end = true,
                        .quoted = true,
                        .needs_unescape = needs_unescape,
                        .location = location,
                    };
                }

                const terminator = self.input[after_quote_index];
                if (terminator == options.delimiter) {
                    self.byte_index = after_quote_index + 1;
                    self.pending_final_empty_field = self.byte_index == self.input.len;
                    self.finishLogicalField(false);
                    return .{
                        .data = data,
                        .row_end = false,
                        .quoted = true,
                        .needs_unescape = needs_unescape,
                        .location = location,
                    };
                }

                if (isRowEnding(terminator)) {
                    self.byte_index = consumeRowEnding(self.input, after_quote_index);
                    self.finishLogicalField(true);
                    return .{
                        .data = data,
                        .row_end = true,
                        .quoted = true,
                        .needs_unescape = needs_unescape,
                        .location = location,
                    };
                }

                return error.UnexpectedByteAfterQuote;
            }

            return error.UnterminatedQuote;
        }

        fn nextUnquoted(self: *Self) ParseError!FieldSlice {
            const location = self.currentLocation();
            const field_start = self.byte_index;
            var scan_index = self.byte_index;

            while (self.nextStructuralPos(scan_index)) |special_index| {
                const byte = self.input[special_index];
                if (byte == options.quote) return error.UnexpectedQuote;

                if (byte == options.delimiter) {
                    self.byte_index = special_index + 1;
                    self.pending_final_empty_field = self.byte_index == self.input.len;
                    self.finishLogicalField(false);
                    return .{
                        .data = self.input[field_start..special_index],
                        .row_end = false,
                        .quoted = false,
                        .needs_unescape = false,
                        .location = location,
                    };
                }

                if (isRowEnding(byte)) {
                    self.byte_index = consumeRowEnding(self.input, special_index);
                    self.finishLogicalField(true);
                    return .{
                        .data = self.input[field_start..special_index],
                        .row_end = true,
                        .quoted = false,
                        .needs_unescape = false,
                        .location = location,
                    };
                }

                scan_index = special_index + 1;
            }

            self.byte_index = self.input.len;
            self.finishLogicalField(true);
            return .{
                .data = self.input[field_start..],
                .row_end = true,
                .quoted = false,
                .needs_unescape = false,
                .location = location,
            };
        }

        fn currentLocation(self: Self) ParseLocation {
            return .{
                .row = self.row_index,
                .column = self.column_index,
                .byte_offset = self.byte_index,
                .line = 0,
                .line_column = 0,
            };
        }

        fn finishLogicalField(self: *Self, row_end: bool) void {
            if (row_end) {
                self.row_index += 1;
                self.column_index = 0;
            } else {
                self.column_index += 1;
            }
        }

        fn nextStructuralPos(self: *Self, start_index: usize) ?usize {
            while (self.structural_mask != 0) {
                const lane: usize = @intCast(@ctz(self.structural_mask));
                const byte_index = self.structural_offset + lane;
                self.structural_mask &= self.structural_mask -% 1;
                if (byte_index >= start_index) return byte_index;
            }

            var index = start_index;
            const delimiter_vector: @Vector(structural_vector_lanes, u8) = @splat(options.delimiter);
            const quote_vector: @Vector(structural_vector_lanes, u8) = @splat(options.quote);
            const lf_vector: @Vector(structural_vector_lanes, u8) = @splat('\n');
            const cr_vector: @Vector(structural_vector_lanes, u8) = @splat('\r');

            while (index + structural_vector_lanes <= self.input.len) : (index += structural_vector_lanes) {
                const bytes: @Vector(structural_vector_lanes, u8) = self.input[index..][0..structural_vector_lanes].*;
                const matches = (bytes == delimiter_vector) | (bytes == quote_vector) | (bytes == lf_vector) | (bytes == cr_vector);
                self.structural_mask = @bitCast(matches);
                if (self.structural_mask != 0) {
                    self.structural_offset = index;
                    const lane: usize = @intCast(@ctz(self.structural_mask));
                    self.structural_mask &= self.structural_mask -% 1;
                    return index + lane;
                }
            }

            while (index < self.input.len) : (index += 1) {
                const byte = self.input[index];
                if (byte == options.delimiter or byte == options.quote or byte == '\n' or byte == '\r') return index;
            }

            return null;
        }
    };
}

fn findScalarStructuralPos(input: []const u8, start_index: usize, needle: u8) ?usize {
    var index = start_index;
    const needle_vector: @Vector(structural_vector_lanes, u8) = @splat(needle);

    while (index + structural_vector_lanes <= input.len) : (index += structural_vector_lanes) {
        const bytes: @Vector(structural_vector_lanes, u8) = input[index..][0..structural_vector_lanes].*;
        const matches = bytes == needle_vector;
        if (@reduce(.Or, matches)) {
            inline for (0..structural_vector_lanes) |lane| {
                if (matches[lane]) return index + lane;
            }
        }
    }

    return std.mem.findScalarPos(u8, input, index, needle);
}

fn findFieldStructuralPos(input: []const u8, start_index: usize, delimiter: u8, quote: u8) ?usize {
    var index = start_index;
    const delimiter_vector: @Vector(structural_vector_lanes, u8) = @splat(delimiter);
    const quote_vector: @Vector(structural_vector_lanes, u8) = @splat(quote);
    const lf_vector: @Vector(structural_vector_lanes, u8) = @splat('\n');
    const cr_vector: @Vector(structural_vector_lanes, u8) = @splat('\r');

    while (index + structural_vector_lanes <= input.len) : (index += structural_vector_lanes) {
        const bytes: @Vector(structural_vector_lanes, u8) = input[index..][0..structural_vector_lanes].*;
        const matches = (bytes == delimiter_vector) | (bytes == quote_vector) | (bytes == lf_vector) | (bytes == cr_vector);
        if (@reduce(.Or, matches)) {
            inline for (0..structural_vector_lanes) |lane| {
                if (matches[lane]) return index + lane;
            }
        }
    }

    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte == delimiter or byte == quote or byte == '\n' or byte == '\r') return index;
    }
    return null;
}

fn findTerminatorStructuralPos(input: []const u8, start_index: usize, delimiter: u8) ?usize {
    var index = start_index;
    const delimiter_vector: @Vector(structural_vector_lanes, u8) = @splat(delimiter);
    const lf_vector: @Vector(structural_vector_lanes, u8) = @splat('\n');
    const cr_vector: @Vector(structural_vector_lanes, u8) = @splat('\r');

    while (index + structural_vector_lanes <= input.len) : (index += structural_vector_lanes) {
        const bytes: @Vector(structural_vector_lanes, u8) = input[index..][0..structural_vector_lanes].*;
        const matches = (bytes == delimiter_vector) | (bytes == lf_vector) | (bytes == cr_vector);
        if (@reduce(.Or, matches)) {
            inline for (0..structural_vector_lanes) |lane| {
                if (matches[lane]) return index + lane;
            }
        }
    }

    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte == delimiter or byte == '\n' or byte == '\r') return index;
    }
    return null;
}

fn completeRowPrefixLen(input: []const u8, options: ParseOptions, finish_input: bool) ?usize {
    var index: usize = 0;
    var last_complete: ?usize = null;
    var in_quotes = false;
    var quote_closed = false;
    var field_start = true;
    var row_start = true;

    while (index < input.len) {
        const byte = input[index];

        if (in_quotes) {
            if (byte == options.quote) {
                if (index + 1 < input.len and input[index + 1] == options.quote) {
                    index += 2;
                    continue;
                }
                in_quotes = false;
                quote_closed = true;
            }
            index += 1;
            continue;
        }

        if (quote_closed) {
            if (byte == options.delimiter) {
                quote_closed = false;
                field_start = true;
                row_start = false;
                index += 1;
                continue;
            }
            if (isRowEnding(byte)) {
                if (byte == '\r' and !finish_input and index + 1 == input.len) return last_complete;
                const end_index = consumeRowEnding(input, index);
                last_complete = end_index;
                quote_closed = false;
                field_start = true;
                row_start = true;
                index = end_index;
                continue;
            }
            row_start = false;
            index += 1;
            continue;
        }

        if (row_start) {
            if (options.comment) |comment| {
                if (byte == comment) {
                    while (index < input.len and !isRowEnding(input[index])) : (index += 1) {}
                    if (index >= input.len) return last_complete;
                    if (input[index] == '\r' and !finish_input and index + 1 == input.len) return last_complete;
                    const end_index = consumeRowEnding(input, index);
                    last_complete = end_index;
                    field_start = true;
                    row_start = true;
                    index = end_index;
                    continue;
                }
            }
        }

        if (byte == options.quote and field_start) {
            in_quotes = true;
            field_start = false;
            row_start = false;
            index += 1;
            continue;
        }

        if (byte == options.delimiter) {
            field_start = true;
            row_start = false;
            index += 1;
            continue;
        }

        if (isRowEnding(byte)) {
            if (byte == '\r' and !finish_input and index + 1 == input.len) return last_complete;
            const end_index = consumeRowEnding(input, index);
            last_complete = end_index;
            field_start = true;
            row_start = true;
            index = end_index;
            continue;
        }

        field_start = false;
        row_start = false;
        index += 1;
    }

    return last_complete;
}

fn validateParseOptions(options: ParseOptions) ParseError!void {
    if (options.delimiter == options.quote) return error.InvalidOptions;
    if (isRowEnding(options.delimiter) or isRowEnding(options.quote)) return error.InvalidOptions;
    if (options.comment) |comment| {
        if (comment == options.delimiter or comment == options.quote or isRowEnding(comment)) return error.InvalidOptions;
    }
}

fn readOnlyProt() std.posix.PROT {
    return switch (@typeInfo(std.posix.PROT)) {
        .@"struct" => .{ .READ = true },
        .int => 1,
        .comptime_int => 1,
        else => @compileError("unsupported std.posix.PROT shape"),
    };
}

fn startsWithUtf8Bom(input: []const u8) bool {
    return input.len >= 3 and input[0] == 0xef and input[1] == 0xbb and input[2] == 0xbf;
}

fn trimField(field: []const u8, quoted: bool, options: ParseOptions) []const u8 {
    return switch (options.trim) {
        .none => field,
        .unquoted => if (quoted) field else std.mem.trim(u8, field, " \t"),
        .all => std.mem.trim(u8, field, " \t"),
    };
}

fn updatePhysicalPosition(bytes: []const u8, line_index: *usize, line_column_index: *usize) void {
    if (std.mem.findAny(u8, bytes, "\r\n") == null) {
        line_column_index.* += bytes.len;
        return;
    }

    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] == '\r') {
            line_index.* += 1;
            line_column_index.* = 0;
            if (index + 1 < bytes.len and bytes[index + 1] == '\n') {
                index += 2;
            } else {
                index += 1;
            }
        } else if (bytes[index] == '\n') {
            line_index.* += 1;
            line_column_index.* = 0;
            index += 1;
        } else {
            line_column_index.* += 1;
            index += 1;
        }
    }
}

fn emptyLocation() ParseLocation {
    return .{
        .row = 0,
        .column = 0,
        .byte_offset = 0,
        .line = 0,
        .line_column = 0,
    };
}

fn diagnosticForError(err: ParseError, location: ParseLocation) ParseDiagnostic {
    return .{
        .code = codeForError(err),
        .location = location,
        .message = messageForError(err),
    };
}

fn codeForError(err: ParseError) ParseErrorCode {
    return switch (err) {
        error.InvalidOptions => .invalid_options,
        error.RaggedRow => .ragged_row,
        error.MissingHeader => .missing_header,
        error.DuplicateHeader => .duplicate_header,
        error.UnknownColumn => .unknown_column,
        error.UnexpectedQuote => .unexpected_quote,
        error.UnexpectedByteAfterQuote => .unexpected_byte_after_quote,
        error.UnterminatedQuote => .unterminated_quote,
        error.InputTooLarge => .input_too_large,
        error.RowTooLarge => .row_too_large,
        error.OutOfMemory => .out_of_memory,
    };
}

fn messageForError(err: ParseError) []const u8 {
    return switch (err) {
        error.InvalidOptions => "invalid CSV options",
        error.RaggedRow => "row has an unexpected number of fields",
        error.MissingHeader => "CSV input does not contain a header row",
        error.DuplicateHeader => "header row contains duplicate names",
        error.UnknownColumn => "unknown header column",
        error.UnexpectedQuote => "unexpected quote in unquoted field",
        error.UnexpectedByteAfterQuote => "unexpected byte after closing quote",
        error.UnterminatedQuote => "unterminated quoted field",
        error.InputTooLarge => "input exceeds borrowed table compact index range",
        error.RowTooLarge => "row exceeds configured byte limit",
        error.OutOfMemory => "out of memory",
    };
}

fn unescapeQuotedField(allocator: std.mem.Allocator, field: []const u8, quote: u8) std.mem.Allocator.Error![]const u8 {
    var output_len: usize = field.len;
    var scan_index: usize = 0;
    while (scan_index < field.len) {
        if (field[scan_index] == quote and scan_index + 1 < field.len and field[scan_index + 1] == quote) {
            output_len -= 1;
            scan_index += 2;
        } else {
            scan_index += 1;
        }
    }

    const output = try allocator.alloc(u8, output_len);
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < field.len) {
        if (field[read_index] == quote and read_index + 1 < field.len and field[read_index + 1] == quote) {
            output[write_index] = quote;
            read_index += 2;
        } else {
            output[write_index] = field[read_index];
            read_index += 1;
        }
        write_index += 1;
    }

    return output;
}

fn compactBorrowedIndex(value: usize) ParseError!BorrowedIndex {
    if (value > std.math.maxInt(BorrowedIndex)) return error.InputTooLarge;
    return @intCast(value);
}

const ParallelChunk = struct {
    start: usize,
    end: usize,
};

const ParallelChunkResult = struct {
    table: ?BorrowedTable = null,
    err: ?anyerror = null,
};

fn effectiveWorkerCount(input_len: usize, options: ParallelParseOptions) !usize {
    if (input_len == 0) return 1;
    const min_chunk_bytes = @max(options.min_chunk_bytes, 1);
    const chunk_limited = @max(input_len / min_chunk_bytes, 1);
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const requested = if (options.max_threads == 0) cpu_count else options.max_threads;
    return @max(@min(requested, chunk_limited), 1);
}

fn buildParallelChunks(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
    requested_min_chunk_bytes: usize,
    requested_workers: usize,
) ![]ParallelChunk {
    if (input.len == 0) {
        const chunks = try allocator.alloc(ParallelChunk, 1);
        chunks[0] = .{ .start = 0, .end = 0 };
        return chunks;
    }

    const min_chunk_bytes = @max(requested_min_chunk_bytes, 1);
    if (requested_workers <= 1 or input.len <= min_chunk_bytes) {
        const chunks = try allocator.alloc(ParallelChunk, 1);
        chunks[0] = .{ .start = 0, .end = input.len };
        return chunks;
    }

    var chunks: std.ArrayList(ParallelChunk) = .empty;
    errdefer chunks.deinit(allocator);

    const target_chunk_bytes = @max(input.len / requested_workers, min_chunk_bytes);
    var start: usize = 0;
    while (start < input.len) {
        const remaining = input.len - start;
        if (remaining <= target_chunk_bytes) {
            try chunks.append(allocator, .{ .start = start, .end = input.len });
            break;
        }

        const target_end = start + target_chunk_bytes;
        const end = findParallelChunkEnd(input, start, target_end, options) orelse input.len;
        if (end <= start or end >= input.len) {
            try chunks.append(allocator, .{ .start = start, .end = input.len });
            break;
        }

        try chunks.append(allocator, .{ .start = start, .end = end });
        start = end;
    }

    return try chunks.toOwnedSlice(allocator);
}

fn findParallelChunkEnd(input: []const u8, start: usize, target_end: usize, options: ParseOptions) ?usize {
    const scan_step = 64 * 1024;
    var window_end = @min(target_end, input.len);
    while (window_end < input.len) {
        if (completeRowPrefixLen(input[start..window_end], options, false)) |prefix_len| {
            const end = start + prefix_len;
            if (end >= target_end) return end;
        }
        window_end = @min(input.len, window_end + scan_step);
    }
    return null;
}

fn parseBorrowedParallelWorker(result: *ParallelChunkResult, input: []const u8, options: ParseOptions) void {
    result.table = parseBorrowed(std.heap.smp_allocator, input, options) catch |err| {
        result.err = err;
        return;
    };
}

fn deinitParallelChunkResults(results: []ParallelChunkResult) void {
    for (results) |*result| {
        if (result.table) |*table| {
            table.deinit(std.heap.smp_allocator);
            result.table = null;
        }
    }
}

fn mergeParallelBorrowedTables(
    allocator: std.mem.Allocator,
    input: []const u8,
    chunks: []const ParallelChunk,
    results: []ParallelChunkResult,
) !BorrowedTable {
    if (input.len > std.math.maxInt(BorrowedIndex)) return error.InputTooLarge;

    var row_count: usize = 0;
    var field_count: usize = 0;
    var quote_arena_len: usize = 0;
    for (results) |result| {
        const table = result.table.?;
        row_count += table.rows.len;
        field_count += table.fields.len;
        quote_arena_len += table.quote_arena.len;
    }

    const rows = try allocator.alloc(BorrowedRow, row_count);
    errdefer allocator.free(rows);
    const fields = try allocator.alloc(BorrowedField, field_count);
    errdefer allocator.free(fields);
    const quote_arena = try allocator.alloc(u8, quote_arena_len);
    errdefer allocator.free(quote_arena);

    var row_offset: usize = 0;
    var field_offset: usize = 0;
    var quote_offset: usize = 0;
    for (chunks, results) |chunk, *result| {
        var table = result.table.?;

        for (table.rows) |row_meta| {
            rows[row_offset] = .{
                .byte_offset = try compactBorrowedIndex(chunk.start + @as(usize, @intCast(row_meta.byte_offset))),
                .fields_start = try compactBorrowedIndex(field_offset + @as(usize, @intCast(row_meta.fields_start))),
                .field_count = row_meta.field_count,
            };
            row_offset += 1;
        }

        for (table.fields) |field_meta| {
            const old_start: usize = @intCast(field_meta.start);
            fields[field_offset] = if (field_meta.realized)
                .{
                    .start = try compactBorrowedIndex(quote_offset + old_start),
                    .len = field_meta.len,
                    .realized = true,
                }
            else
                .{
                    .start = try compactBorrowedIndex(chunk.start + old_start),
                    .len = field_meta.len,
                    .realized = false,
                };
            field_offset += 1;
        }

        @memcpy(quote_arena[quote_offset..][0..table.quote_arena.len], table.quote_arena);
        quote_offset += table.quote_arena.len;
        table.deinit(std.heap.smp_allocator);
        result.table = null;
    }

    return .{
        .source = input,
        .rows = rows,
        .fields = fields,
        .quote_arena = quote_arena,
    };
}

const BorrowedParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    options: ParseOptions,
    diagnostic: ?*ParseDiagnostic = null,
    expected_fields: ?usize = null,
    row_start_offset: usize = 0,
    rows: std.ArrayList(BorrowedRow) = .empty,
    fields: std.ArrayList(BorrowedField) = .empty,
    quote_arena: std.ArrayList(u8) = .empty,
    current_row_fields_start: usize = 0,

    fn deinit(self: *BorrowedParser) void {
        self.rows.deinit(self.allocator);
        self.fields.deinit(self.allocator);
        self.quote_arena.deinit(self.allocator);
    }

    fn appendField(self: *BorrowedParser, field: FieldSlice) ParseError!void {
        if (self.options.max_row_bytes) |max_row_bytes| {
            if (field.location.byte_offset >= self.row_start_offset and field.location.byte_offset - self.row_start_offset > max_row_bytes) {
                self.setDiagnostic(.row_too_large, field.location, "row exceeds configured byte limit");
                return error.RowTooLarge;
            }
        }

        const field_meta = if (field.data.len == 0)
            BorrowedField{ .start = 0, .len = 0 }
        else if (field.needs_unescape)
            try self.appendUnescapedQuotedField(field.data, field.location)
        else
            BorrowedField{
                .start = try self.sourceOffset(field.data, field.location),
                .len = try self.compactIndex(field.data.len, field.location),
            };

        try self.fields.append(self.allocator, field_meta);
    }

    fn finishRow(self: *BorrowedParser, location: ParseLocation) ParseError!void {
        const field_count = self.fields.items.len - self.current_row_fields_start;
        if (field_count == 1 and self.fields.items[self.current_row_fields_start].len == 0 and self.options.skip_empty_rows) {
            self.fields.items.len = self.current_row_fields_start;
            self.row_start_offset = location.byte_offset;
            return;
        }

        try self.applyRaggedPolicy(location);
        try self.rows.append(self.allocator, .{
            .byte_offset = try self.compactIndex(self.row_start_offset, location),
            .fields_start = try self.compactIndex(self.current_row_fields_start, location),
            .field_count = try self.compactIndex(self.fields.items.len - self.current_row_fields_start, location),
        });
        self.current_row_fields_start = self.fields.items.len;
        self.row_start_offset = location.byte_offset;
    }

    fn applyRaggedPolicy(self: *BorrowedParser, location: ParseLocation) ParseError!void {
        const field_count = self.fields.items.len - self.current_row_fields_start;
        const expected = self.expected_fields orelse {
            if (self.options.ragged_row_policy != .allow) self.expected_fields = field_count;
            return;
        };

        if (field_count == expected) return;

        switch (self.options.ragged_row_policy) {
            .allow => {},
            .error_on_ragged => {
                self.setDiagnostic(.ragged_row, location, "row has an unexpected number of fields");
                return error.RaggedRow;
            },
            .pad => {
                while (self.fields.items.len - self.current_row_fields_start < expected) {
                    try self.fields.append(self.allocator, .{ .start = 0, .len = 0 });
                }
                if (self.fields.items.len - self.current_row_fields_start > expected) {
                    self.fields.items.len = self.current_row_fields_start + expected;
                }
            },
            .truncate => {
                if (self.fields.items.len - self.current_row_fields_start > expected) {
                    self.fields.items.len = self.current_row_fields_start + expected;
                }
            },
        }
    }

    fn appendUnescapedQuotedField(self: *BorrowedParser, field: []const u8, location: ParseLocation) ParseError!BorrowedField {
        const start = try self.compactIndex(self.quote_arena.items.len, location);
        const max_index: usize = std.math.maxInt(BorrowedIndex);
        if (field.len > max_index or self.quote_arena.items.len > max_index - field.len) {
            self.setDiagnostic(.input_too_large, location, "quote arena exceeds borrowed table compact index range");
            return error.InputTooLarge;
        }

        try self.quote_arena.ensureUnusedCapacity(self.allocator, field.len);
        const start_offset = self.quote_arena.items.len;
        self.quote_arena.items.len += field.len;

        var read_index: usize = 0;
        var write_index = start_offset;
        while (read_index < field.len) {
            if (field[read_index] == self.options.quote and read_index + 1 < field.len and field[read_index + 1] == self.options.quote) {
                self.quote_arena.items[write_index] = self.options.quote;
                write_index += 1;
                read_index += 2;
            } else {
                self.quote_arena.items[write_index] = field[read_index];
                write_index += 1;
                read_index += 1;
            }
        }
        self.quote_arena.items.len = write_index;

        return .{
            .start = start,
            .len = try self.compactIndex(self.quote_arena.items.len - start_offset, location),
            .realized = true,
        };
    }

    fn sourceOffset(self: *BorrowedParser, field: []const u8, location: ParseLocation) ParseError!BorrowedIndex {
        return self.compactIndex(@intFromPtr(field.ptr) - @intFromPtr(self.input.ptr), location);
    }

    fn compactIndex(self: *BorrowedParser, value: usize, location: ParseLocation) ParseError!BorrowedIndex {
        return compactBorrowedIndex(value) catch |err| {
            self.setDiagnostic(.input_too_large, location, "input exceeds borrowed table compact index range");
            return err;
        };
    }

    fn toOwnedTable(self: *BorrowedParser) ParseError!BorrowedTable {
        const rows = try self.rows.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(rows);

        const fields = try self.fields.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(fields);

        const quote_arena = try self.quote_arena.toOwnedSlice(self.allocator);
        return .{
            .source = self.input,
            .rows = rows,
            .fields = fields,
            .quote_arena = quote_arena,
        };
    }

    fn setDiagnostic(self: *BorrowedParser, code: ParseErrorCode, location: ParseLocation, message: []const u8) void {
        if (self.diagnostic) |out| out.* = .{
            .code = code,
            .location = location,
            .message = message,
        };
    }
};

const FastBorrowedParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    quote: u8,
    row_start_offset: usize = 0,
    rows: std.ArrayList(BorrowedRow) = .empty,
    fields: std.ArrayList(BorrowedField) = .empty,
    quote_arena: std.ArrayList(u8) = .empty,
    current_row_fields_start: usize = 0,

    fn deinit(self: *FastBorrowedParser) void {
        self.rows.deinit(self.allocator);
        self.fields.deinit(self.allocator);
        self.quote_arena.deinit(self.allocator);
    }

    fn appendField(self: *FastBorrowedParser, field: FieldSlice) ParseError!void {
        const field_meta = if (field.data.len == 0)
            BorrowedField{ .start = 0, .len = 0 }
        else if (field.needs_unescape)
            try self.appendUnescapedQuotedField(field.data)
        else
            BorrowedField{
                .start = try compactBorrowedIndex(@intFromPtr(field.data.ptr) - @intFromPtr(self.input.ptr)),
                .len = try compactBorrowedIndex(field.data.len),
            };

        try self.fields.append(self.allocator, field_meta);
    }

    fn finishRow(self: *FastBorrowedParser, location: ParseLocation) ParseError!void {
        try self.rows.append(self.allocator, .{
            .byte_offset = try compactBorrowedIndex(self.row_start_offset),
            .fields_start = try compactBorrowedIndex(self.current_row_fields_start),
            .field_count = try compactBorrowedIndex(self.fields.items.len - self.current_row_fields_start),
        });
        self.current_row_fields_start = self.fields.items.len;
        self.row_start_offset = location.byte_offset;
    }

    fn appendUnescapedQuotedField(self: *FastBorrowedParser, field: []const u8) ParseError!BorrowedField {
        const start = try compactBorrowedIndex(self.quote_arena.items.len);
        const max_index: usize = std.math.maxInt(BorrowedIndex);
        if (field.len > max_index or self.quote_arena.items.len > max_index - field.len) return error.InputTooLarge;

        try self.quote_arena.ensureUnusedCapacity(self.allocator, field.len);
        const start_offset = self.quote_arena.items.len;
        self.quote_arena.items.len += field.len;

        var read_index: usize = 0;
        var write_index = start_offset;
        while (read_index < field.len) {
            if (field[read_index] == self.quote and read_index + 1 < field.len and field[read_index + 1] == self.quote) {
                self.quote_arena.items[write_index] = self.quote;
                write_index += 1;
                read_index += 2;
            } else {
                self.quote_arena.items[write_index] = field[read_index];
                write_index += 1;
                read_index += 1;
            }
        }
        self.quote_arena.items.len = write_index;

        return .{
            .start = start,
            .len = try compactBorrowedIndex(self.quote_arena.items.len - start_offset),
            .realized = true,
        };
    }

    fn toOwnedTable(self: *FastBorrowedParser) ParseError!BorrowedTable {
        const rows = try self.rows.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(rows);

        const fields = try self.fields.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(fields);

        const quote_arena = try self.quote_arena.toOwnedSlice(self.allocator);
        return .{
            .source = self.input,
            .rows = rows,
            .fields = fields,
            .quote_arena = quote_arena,
        };
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    options: ParseOptions,
    diagnostic: ?*ParseDiagnostic = null,
    expected_fields: ?usize = null,
    row_start_offset: usize = 0,
    rows: std.ArrayList(Row) = .empty,
    fields: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Parser) void {
        for (self.fields.items) |field| {
            if (field.len != 0) self.allocator.free(field);
        }
        self.fields.deinit(self.allocator);

        for (self.rows.items) |*row| row.deinit(self.allocator);
        self.rows.deinit(self.allocator);
    }

    fn appendField(self: *Parser, field: FieldSlice) ParseError!void {
        if (self.options.max_row_bytes) |max_row_bytes| {
            if (field.location.byte_offset >= self.row_start_offset and field.location.byte_offset - self.row_start_offset > max_row_bytes) {
                self.setDiagnostic(.row_too_large, field.location, "row exceeds configured byte limit");
                return error.RowTooLarge;
            }
        }

        const owned_field: []const u8 = if (field.data.len == 0)
            &.{}
        else if (field.needs_unescape)
            try unescapeQuotedField(self.allocator, field.data, self.options.quote)
        else
            try self.allocator.dupe(u8, field.data);
        errdefer if (owned_field.len != 0) self.allocator.free(owned_field);

        try self.fields.append(self.allocator, owned_field);
    }

    fn finishRow(self: *Parser, location: ParseLocation) ParseError!void {
        if (self.fields.items.len == 1 and self.fields.items[0].len == 0 and self.options.skip_empty_rows) {
            self.freePendingFields();
            self.row_start_offset = location.byte_offset;
            return;
        }

        try self.applyRaggedPolicy(location);
        const owned_fields = try self.fields.toOwnedSlice(self.allocator);
        var row: Row = .{ .fields = owned_fields };
        errdefer row.deinit(self.allocator);

        try self.rows.append(self.allocator, row);
        self.row_start_offset = location.byte_offset;
    }

    fn applyRaggedPolicy(self: *Parser, location: ParseLocation) ParseError!void {
        const expected = self.expected_fields orelse {
            if (self.options.ragged_row_policy != .allow) self.expected_fields = self.fields.items.len;
            return;
        };

        if (self.fields.items.len == expected) return;

        switch (self.options.ragged_row_policy) {
            .allow => {},
            .error_on_ragged => {
                self.setDiagnostic(.ragged_row, location, "row has an unexpected number of fields");
                return error.RaggedRow;
            },
            .pad => {
                while (self.fields.items.len < expected) try self.fields.append(self.allocator, &.{});
                if (self.fields.items.len > expected) {
                    self.freeFieldsFrom(expected);
                    self.fields.items.len = expected;
                }
            },
            .truncate => {
                if (self.fields.items.len > expected) {
                    self.freeFieldsFrom(expected);
                    self.fields.items.len = expected;
                }
            },
        }
    }

    fn freePendingFields(self: *Parser) void {
        self.freeFieldsFrom(0);
        self.fields.clearRetainingCapacity();
    }

    fn freeFieldsFrom(self: *Parser, start_index: usize) void {
        for (self.fields.items[start_index..]) |field| {
            if (field.len != 0) self.allocator.free(field);
        }
    }

    fn setDiagnostic(self: *Parser, code: ParseErrorCode, location: ParseLocation, message: []const u8) void {
        if (self.diagnostic) |out| {
            out.* = .{
                .code = code,
                .location = location,
                .message = message,
            };
        }
    }
};

fn expectBorrowedTablesEqual(expected: *const BorrowedTable, actual: *const BorrowedTable) !void {
    try std.testing.expectEqual(expected.rows.len, actual.rows.len);
    try std.testing.expectEqual(expected.fields.len, actual.fields.len);
    try std.testing.expectEqualStrings(expected.quote_arena, actual.quote_arena);

    for (expected.rows, actual.rows) |expected_row, actual_row| {
        try std.testing.expectEqual(expected_row.byte_offset, actual_row.byte_offset);
        try std.testing.expectEqual(expected_row.fields_start, actual_row.fields_start);
        try std.testing.expectEqual(expected_row.field_count, actual_row.field_count);
    }

    for (expected.fields, actual.fields) |expected_field, actual_field| {
        try std.testing.expectEqual(expected_field.start, actual_field.start);
        try std.testing.expectEqual(expected_field.len, actual_field.len);
        try std.testing.expectEqual(expected_field.realized, actual_field.realized);
    }

    for (0..expected.rows.len) |row_index| {
        const expected_row = try expected.row(row_index);
        const actual_row = try actual.row(row_index);
        try std.testing.expectEqual(expected_row.len(), actual_row.len());
        for (0..expected_row.len()) |column_index| {
            try std.testing.expectEqualStrings(try expected_row.field(column_index), try actual_row.field(column_index));
        }
    }
}

test "parse simple rows" {
    var table = try parse(std.testing.allocator, "name,age\nAda,37\n", .{});
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqualStrings("name", table.rows[0].fields[0]);
    try std.testing.expectEqualStrings("age", table.rows[0].fields[1]);
    try std.testing.expectEqualStrings("Ada", table.rows[1].fields[0]);
    try std.testing.expectEqual(@as(i32, 37), try parseIntField(i32, table.rows[1].fields[1], 10));
}

test "parse quoted delimiter escaped quote and quoted newline" {
    const input = "id,text\n1,\"hello, \"\"Zig\"\"\"\n2,\"two\nlines\"\n";
    var table = try parse(std.testing.allocator, input, .{});
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    try std.testing.expectEqualStrings("hello, \"Zig\"", table.rows[1].fields[1]);
    try std.testing.expectEqualStrings("two\nlines", table.rows[2].fields[1]);
}

test "parse CRLF and trailing empty fields" {
    var table = try parse(std.testing.allocator, "a,b,\r\nc,,d\r\n", .{});
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqual(@as(usize, 3), table.rows[0].fields.len);
    try std.testing.expectEqualStrings("", table.rows[0].fields[2]);
    try std.testing.expectEqualStrings("", table.rows[1].fields[1]);
}

test "parse delimiter at EOF as final empty field" {
    var table = try parse(std.testing.allocator, "a,b,", .{});
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), table.rows.len);
    try std.testing.expectEqual(@as(usize, 3), table.rows[0].fields.len);
    try std.testing.expectEqualStrings("a", table.rows[0].fields[0]);
    try std.testing.expectEqualStrings("b", table.rows[0].fields[1]);
    try std.testing.expectEqualStrings("", table.rows[0].fields[2]);
}

test "parse empty input and blank row" {
    var empty = try parse(std.testing.allocator, "", .{});
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.rows.len);

    var blank = try parse(std.testing.allocator, "\n", .{});
    defer blank.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), blank.rows.len);
    try std.testing.expectEqual(@as(usize, 1), blank.rows[0].fields.len);
    try std.testing.expectEqualStrings("", blank.rows[0].fields[0]);
}

test "reject malformed quote usage" {
    try std.testing.expectError(error.UnexpectedQuote, parse(std.testing.allocator, "a,b\"c\n", .{}));
    try std.testing.expectError(error.UnexpectedByteAfterQuote, parse(std.testing.allocator, "\"a\"b\n", .{}));
    try std.testing.expectError(error.UnterminatedQuote, parse(std.testing.allocator, "\"a\n", .{}));
}

test "diagnostics include row column and byte offset" {
    var diagnostic: ParseDiagnostic = undefined;
    try std.testing.expectError(
        error.UnexpectedByteAfterQuote,
        parseWithDiagnostic(std.testing.allocator, "a,b\n\"c\"x,d\n", .{}, &diagnostic),
    );

    try std.testing.expectEqual(ParseErrorCode.unexpected_byte_after_quote, diagnostic.code);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.location.row);
    try std.testing.expectEqual(@as(usize, 0), diagnostic.location.column);
    try std.testing.expectEqual(@as(usize, 7), diagnostic.location.byte_offset);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.location.line);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.location.line_column);
}

test "reject invalid parse options" {
    try std.testing.expectError(error.InvalidOptions, parse(std.testing.allocator, "a,b\n", .{
        .delimiter = '"',
        .quote = '"',
    }));
    try std.testing.expectError(error.InvalidOptions, parse(std.testing.allocator, "a,b\n", .{
        .delimiter = '\n',
    }));
}

test "parse BOM comments trim empty rows and tolerant quotes" {
    const input = "\xef\xbb\xbf# skip\n\n name , age \n Ada , 37 \n note,b\"c\n";
    var table = try parse(std.testing.allocator, input, .{
        .comment = '#',
        .trim = .unquoted,
        .skip_empty_rows = true,
        .tolerant = true,
    });
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    try std.testing.expectEqualStrings("name", table.rows[0].fields[0]);
    try std.testing.expectEqualStrings("age", table.rows[0].fields[1]);
    try std.testing.expectEqualStrings("Ada", table.rows[1].fields[0]);
    try std.testing.expectEqualStrings("b\"c", table.rows[2].fields[1]);
}

test "ragged row policies error pad and truncate" {
    try std.testing.expectError(error.RaggedRow, parse(std.testing.allocator, "a,b\n1\n", .{
        .ragged_row_policy = .error_on_ragged,
    }));

    var padded = try parse(std.testing.allocator, "a,b,c\n1\n", .{
        .ragged_row_policy = .pad,
    });
    defer padded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), padded.rows[1].fields.len);
    try std.testing.expectEqualStrings("", padded.rows[1].fields[1]);

    var truncated = try parse(std.testing.allocator, "a,b\n1,2,3\n", .{
        .ragged_row_policy = .truncate,
    });
    defer truncated.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), truncated.rows[1].fields.len);
    try std.testing.expectEqualStrings("2", truncated.rows[1].fields[1]);
}

test "field iterator returns borrowed slices and escaped quote marker" {
    const input = "name,\"said \"\"hi\"\"\",age\n";
    var iterator = try FieldIterator.init(input, .{});

    const first = (try iterator.next()).?;
    try std.testing.expect(!first.row_end);
    try std.testing.expect(!first.quoted);
    try std.testing.expect(!first.needs_unescape);
    try std.testing.expect(first.data.ptr == input.ptr);
    try std.testing.expectEqualStrings("name", first.data);

    const second = (try iterator.next()).?;
    try std.testing.expect(!second.row_end);
    try std.testing.expect(second.quoted);
    try std.testing.expect(second.needs_unescape);
    try std.testing.expectEqualStrings("said \"\"hi\"\"", second.data);

    const third = (try iterator.next()).?;
    try std.testing.expect(third.row_end);
    try std.testing.expectEqualStrings("age", third.data);
    try std.testing.expectEqual(@as(?FieldSlice, null), try iterator.next());
}

test "header index and schema decoding" {
    const Person = struct {
        name: []const u8,
        age: u8,
        active: bool,
        score: ?f32,
    };

    var table = try parseWithHeader(std.testing.allocator, "name,age,active,score\nAda,37,true,9.5\n", .{});
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), table.rows.len);
    try std.testing.expectEqual(@as(usize, 2), table.headers.indexOf("active").?);
    try std.testing.expectEqualStrings("37", try table.headers.field(table.rows[0], "age"));

    const person = try decodeRow(Person, table.headers, table.rows[0]);
    try std.testing.expectEqualStrings("Ada", person.name);
    try std.testing.expectEqual(@as(u8, 37), person.age);
    try std.testing.expect(person.active);
    try std.testing.expectApproxEqAbs(@as(f32, 9.5), person.score.?, 0.001);
}

test "borrowed header index field lookup and schema decoding" {
    const Person = struct {
        name: []const u8,
        age: u8,
        active: bool,
        score: ?f32,
    };

    const input = "name,age,active,score,\"display \"\"label\"\"\"\nAda,37,true,9.5,Analyst\n";
    var table = try parseBorrowedWithHeader(std.testing.allocator, input, .{});
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), table.len());
    try std.testing.expectEqual(@as(usize, 2), table.headers.indexOf("active").?);
    try std.testing.expectEqual(@as(usize, 4), table.headers.indexOf("display \"label\"").?);
    try std.testing.expectEqualStrings("Analyst", try table.field(0, "display \"label\""));

    const ada = try table.row(0);
    try std.testing.expectEqualStrings("37", try ada.fieldByName(table.headers, "age"));
    try std.testing.expectError(error.UnknownColumn, ada.fieldByName(table.headers, "missing"));

    const person = try decodeBorrowedRow(Person, table.headers, ada);
    try std.testing.expectEqualStrings("Ada", person.name);
    try std.testing.expectEqual(@as(u8, 37), person.age);
    try std.testing.expect(person.active);
    try std.testing.expectApproxEqAbs(@as(f32, 9.5), person.score.?, 0.001);

    try std.testing.expectError(
        error.DuplicateHeader,
        parseBorrowedWithHeader(std.testing.allocator, "name,name\nAda,Lovelace\n", .{}),
    );
    try std.testing.expectError(error.MissingHeader, parseBorrowedWithHeader(std.testing.allocator, "", .{}));
}

test "header indexes build hash lookup for wide rows" {
    var input: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer input.deinit();

    for (0..128) |column_index| {
        if (column_index != 0) try input.writer.writeByte(',');
        try input.writer.print("col_{d}", .{column_index});
    }
    try input.writer.writeByte('\n');
    for (0..128) |column_index| {
        if (column_index != 0) try input.writer.writeByte(',');
        try input.writer.print("{d}", .{column_index});
    }
    try input.writer.writeByte('\n');

    const bytes = try input.toOwnedSlice();
    defer std.testing.allocator.free(bytes);

    var owning = try parseWithHeader(std.testing.allocator, bytes, .{});
    defer owning.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 128), owning.headers.lookup.size);
    try std.testing.expectEqual(@as(usize, 127), owning.headers.indexOf("col_127").?);
    try std.testing.expectEqualStrings("127", try owning.headers.field(owning.rows[0], "col_127"));

    var borrowed = try parseBorrowedWithHeader(std.testing.allocator, bytes, .{});
    defer borrowed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 128), borrowed.headers.lookup.size);
    try std.testing.expectEqual(@as(usize, 127), borrowed.headers.indexOf("col_127").?);
    try std.testing.expectEqualStrings("127", try borrowed.field(0, "col_127"));
}

test "arena table materialization" {
    var arena_table = try parseArena(std.testing.allocator, "a,b\n1,2\n", .{});
    defer arena_table.deinit();

    try std.testing.expectEqual(@as(usize, 2), arena_table.rows.len);
    try std.testing.expectEqualStrings("2", arena_table.rows[1].fields[1]);
}

test "borrowed table materializes metadata and quote arena only when needed" {
    const input = "name,note\nAda,\"said \"\"hi\"\"\"\nBob,plain\n";
    var table = try parseBorrowed(std.testing.allocator, input, .{});
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    try std.testing.expectEqual(@as(usize, 6), table.fields.len);
    try std.testing.expectEqual(@as(usize, 9), table.quote_arena.len);

    const header = try table.row(0);
    try std.testing.expectEqual(@as(usize, 2), header.len());
    try std.testing.expectEqualStrings("name", try header.field(0));
    try std.testing.expectEqualStrings("note", try header.field(1));

    const ada = try table.row(1);
    try std.testing.expectEqualStrings("Ada", try ada.field(0));
    try std.testing.expectEqualStrings("said \"hi\"", try ada.field(1));
    try std.testing.expect(table.fields[3].realized);

    const bob_note = try table.field(2, 1);
    try std.testing.expectEqualStrings("plain", bob_note);
    try std.testing.expect(!table.fields[5].realized);
    try std.testing.expect(@intFromPtr(bob_note.ptr) >= @intFromPtr(input.ptr));
    try std.testing.expect(@intFromPtr(bob_note.ptr) < @intFromPtr(input.ptr) + input.len);
}

test "borrowed table metadata uses compact indexes" {
    try std.testing.expect(@sizeOf(BorrowedField) <= 12);
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(BorrowedRow));
    try std.testing.expectEqual(@as(BorrowedIndex, std.math.maxInt(BorrowedIndex)), try compactBorrowedIndex(std.math.maxInt(BorrowedIndex)));
    try std.testing.expectError(error.InputTooLarge, compactBorrowedIndex(@as(usize, std.math.maxInt(BorrowedIndex)) + 1));
    try std.testing.expectEqual(ParseErrorCode.input_too_large, codeForError(error.InputTooLarge));
}

test "borrowed table applies ragged row policies" {
    var padded = try parseBorrowed(std.testing.allocator, "a,b\n1\n2,3,4\n", .{ .ragged_row_policy = .pad });
    defer padded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), padded.rows.len);
    try std.testing.expectEqualStrings("", try padded.field(1, 1));
    try std.testing.expectEqual(@as(usize, 2), padded.rows[2].field_count);

    var truncated = try parseBorrowed(std.testing.allocator, "a,b\n1\n2,3,4\n", .{ .ragged_row_policy = .truncate });
    defer truncated.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), truncated.rows.len);
    try std.testing.expectEqual(@as(usize, 2), truncated.rows[2].field_count);
}

test "parallel borrowed parser preserves order across quoted newlines" {
    const input =
        "id,note,value\n" ++
        "1,plain,10\n" ++
        "2,\"line one\nline two\",20\n" ++
        "3,\"said \"\"hi\"\"\",30\n" ++
        "4,last,40\n";

    var serial = try parseBorrowed(std.testing.allocator, input, .{});
    defer serial.deinit(std.testing.allocator);

    var parallel = try parseBorrowedParallel(std.testing.allocator, input, .{}, .{
        .min_chunk_bytes = 16,
        .max_threads = 4,
    });
    defer parallel.deinit(std.testing.allocator);

    try std.testing.expectEqual(serial.rows.len, parallel.rows.len);
    try std.testing.expectEqual(serial.fields.len, parallel.fields.len);
    for (0..serial.rows.len) |row_index| {
        const serial_row = try serial.row(row_index);
        const parallel_row = try parallel.row(row_index);
        try std.testing.expectEqual(serial_row.len(), parallel_row.len());
        for (0..serial_row.len()) |column_index| {
            try std.testing.expectEqualStrings(try serial_row.field(column_index), try parallel_row.field(column_index));
        }
    }

    try std.testing.expectEqualStrings("line one\nline two", try parallel.field(2, 1));
    try std.testing.expectEqualStrings("said \"hi\"", try parallel.field(3, 1));
    const borrowed_plain = try parallel.field(1, 1);
    try std.testing.expect(@intFromPtr(borrowed_plain.ptr) >= @intFromPtr(input.ptr));
    try std.testing.expect(@intFromPtr(borrowed_plain.ptr) < @intFromPtr(input.ptr) + input.len);
}

test "streaming parser handles chunk boundaries inside escaped quotes" {
    const Context = struct {
        seen: usize = 0,

        fn onRow(self: *@This(), row: Row) !void {
            switch (self.seen) {
                0 => {
                    try std.testing.expectEqualStrings("id", row.fields[0]);
                    try std.testing.expectEqualStrings("text", row.fields[1]);
                },
                1 => {
                    try std.testing.expectEqualStrings("1", row.fields[0]);
                    try std.testing.expectEqualStrings("a\"b", row.fields[1]);
                },
                2 => {
                    try std.testing.expectEqualStrings("2", row.fields[0]);
                    try std.testing.expectEqualStrings("c", row.fields[1]);
                },
                else => return error.TooManyRows,
            }
            self.seen += 1;
        }
    };

    var context: Context = .{};
    var parser = try StreamingParser.init(std.testing.allocator, .{});
    defer parser.deinit();

    try parser.feed("id,text\n1,\"a\"", Context, &context, Context.onRow);
    try parser.feed("\"b\"\n2,c\n", Context, &context, Context.onRow);
    try parser.finish(Context, &context, Context.onRow);

    try std.testing.expectEqual(@as(usize, 3), context.seen);
}

test "streaming borrowed parser emits borrowed rows across chunk boundaries" {
    const Context = struct {
        seen: usize = 0,
        fields: usize = 0,
        saw_borrowed_plain: bool = false,

        fn onRow(self: *@This(), row: StreamingBorrowedRow) !void {
            self.fields += row.len();
            switch (self.seen) {
                0 => {
                    try std.testing.expectEqualStrings("id", try row.field(0));
                    try std.testing.expectEqualStrings("text", try row.field(1));
                },
                1 => {
                    try std.testing.expectEqualStrings("1", try row.field(0));
                    try std.testing.expectEqualStrings("a\"b", try row.field(1));
                },
                2 => {
                    const plain = try row.field(1);
                    try std.testing.expectEqualStrings("plain", plain);
                    try std.testing.expect(@intFromPtr(plain.ptr) >= @intFromPtr(row.source.ptr));
                    try std.testing.expect(@intFromPtr(plain.ptr) < @intFromPtr(row.source.ptr) + row.source.len);
                    self.saw_borrowed_plain = true;
                },
                3 => {
                    try std.testing.expectEqualStrings("3", try row.field(0));
                    try std.testing.expectEqualStrings("final", try row.field(1));
                },
                else => return error.TooManyRows,
            }
            self.seen += 1;
        }
    };

    var context: Context = .{};
    var parser = try StreamingBorrowedParser.init(std.testing.allocator, .{});
    defer parser.deinit();

    try parser.feed("\xef\xbb\xbfid,text\r", Context, &context, Context.onRow);
    try std.testing.expectEqual(@as(usize, 0), context.seen);
    try parser.feed("\n1,\"a\"", Context, &context, Context.onRow);
    try parser.feed("\"b\"\n2,plain\n3,final", Context, &context, Context.onRow);
    try std.testing.expectEqual(@as(usize, 3), context.seen);
    try parser.finish(Context, &context, Context.onRow);

    try std.testing.expectEqual(@as(usize, 4), context.seen);
    try std.testing.expectEqual(@as(usize, 8), context.fields);
    try std.testing.expect(context.saw_borrowed_plain);
}

test "streaming borrowed parser borrows complete chunks without copying" {
    const Context = struct {
        source_ptr: [3][*]const u8 = undefined,
        plain_ptr: [3][*]const u8 = undefined,
        seen: usize = 0,

        fn onRow(self: *@This(), row: StreamingBorrowedRow) !void {
            self.source_ptr[self.seen] = row.source.ptr;
            const plain = try row.field(1);
            self.plain_ptr[self.seen] = plain.ptr;
            self.seen += 1;
        }
    };

    const first_chunk = "a,b\n1,2\n";
    const second_chunk = "3,4\n";

    var context: Context = .{};
    var parser = try StreamingBorrowedParser.init(std.testing.allocator, .{});
    defer parser.deinit();

    try parser.feed(first_chunk, Context, &context, Context.onRow);
    try parser.feed(second_chunk, Context, &context, Context.onRow);
    try parser.finish(Context, &context, Context.onRow);

    try std.testing.expectEqual(@as(usize, 3), context.seen);
    try std.testing.expect(context.source_ptr[0] == first_chunk.ptr);
    try std.testing.expect(@intFromPtr(context.plain_ptr[0]) >= @intFromPtr(first_chunk.ptr));
    try std.testing.expect(@intFromPtr(context.plain_ptr[0]) < @intFromPtr(first_chunk.ptr) + first_chunk.len);
    try std.testing.expect(context.source_ptr[1] == first_chunk.ptr);
    try std.testing.expect(context.source_ptr[2] == second_chunk.ptr);
}

test "file chunk reader and mmap parser" {
    const Context = struct {
        rows: usize = 0,
        fields: usize = 0,

        fn onRow(self: *@This(), row: Row) !void {
            self.rows += 1;
            self.fields += row.fields.len;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.csv",
        .data = "a,b\n1,2\n3,4\n",
    });

    var file = try tmp.dir.openFile(std.testing.io, "sample.csv", .{});
    defer file.close(std.testing.io);

    var context: Context = .{};
    try parseFileChunks(std.testing.allocator, file, std.testing.io, .{}, 3, Context, &context, Context.onRow);
    try std.testing.expectEqual(@as(usize, 3), context.rows);
    try std.testing.expectEqual(@as(usize, 6), context.fields);

    const BorrowedContext = struct {
        rows: usize = 0,
        fields: usize = 0,

        fn onRow(self: *@This(), row: StreamingBorrowedRow) !void {
            self.rows += 1;
            self.fields += row.len();
            if (self.rows == 3) try std.testing.expectEqualStrings("4", try row.field(1));
        }
    };

    var borrowed_file = try tmp.dir.openFile(std.testing.io, "sample.csv", .{});
    defer borrowed_file.close(std.testing.io);

    var borrowed_context: BorrowedContext = .{};
    try parseBorrowedFileChunks(std.testing.allocator, borrowed_file, std.testing.io, .{}, 3, BorrowedContext, &borrowed_context, BorrowedContext.onRow);
    try std.testing.expectEqual(@as(usize, 3), borrowed_context.rows);
    try std.testing.expectEqual(@as(usize, 6), borrowed_context.fields);

    var mapped = try mapFile(file, std.testing.io);
    defer mapped.deinit();

    var table = try parseMapped(std.testing.allocator, mapped, .{});
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    try std.testing.expectEqualStrings("4", table.rows[2].fields[1]);
}

test "fast field counter matches strict iterator on edge cases" {
    const cases = [_]struct {
        input: []const u8,
        fields: usize,
    }{
        .{ .input = "", .fields = 0 },
        .{ .input = "a,b,c\n1,2,3\n", .fields = 6 },
        .{ .input = "a,\"b,c\",d\n1,2,3\n", .fields = 6 },
        .{ .input = "a,\"b\"\"c\",d\n", .fields = 3 },
        .{ .input = "a,\"b\nc\",d\n1,2,3\n", .fields = 6 },
        .{ .input = "a,b,c\r\n1,2,3\r\n", .fields = 6 },
        .{ .input = "a,b,\n1,2,\n", .fields = 6 },
        .{ .input = "a,b\n\n1,2\n", .fields = 5 },
        .{ .input = "\"a\nb\"\n", .fields = 1 },
        .{ .input = "\"a,b\nc,d\"\n", .fields = 1 },
        .{ .input = "a,", .fields = 2 },
        .{ .input = "\"a\",", .fields = 2 },
        .{ .input = "\xef\xbb\xbfa,b\n", .fields = 2 },
    };

    for (cases) |case| {
        var iterator = try FieldIterator.init(case.input, .{});
        var iterator_fields: usize = 0;
        while (try iterator.next()) |_| iterator_fields += 1;

        try std.testing.expectEqual(case.fields, iterator_fields);
        try std.testing.expectEqual(case.fields, try countFieldsFast(.{}, case.input));
    }
}

test "fast field counter rejects malformed strict quotes" {
    try std.testing.expectError(error.UnexpectedQuote, countFieldsFast(.{}, "a,b\"c,d\n"));
    try std.testing.expectError(error.UnexpectedByteAfterQuote, countFieldsFast(.{}, "a,\"b\"x,d\n"));
    try std.testing.expectError(error.UnterminatedQuote, countFieldsFast(.{}, "a,\"b,c\n"));
}

test "fast borrowed path matches general borrowed parser" {
    const cases = [_][]const u8{
        "",
        "a,b,c\n1,2,3\n",
        "a,\"b,c\",d\n1,2,3\n",
        "a,\"b\"\"c\",d\n",
        "a,\"b\nc\",d\n1,2,3\n",
        "a,b,c\r\n1,2,3\r\n",
        "a,b,\n1,2,\n",
        "a,b\n\n1,2\n",
        "\"a\nb\"\n",
        "\"a,b\nc,d\"\n",
        "a,",
        "\"a\",",
        "\xef\xbb\xbfa,b\n",
    };

    for (cases) |input| {
        var fast = try parseBorrowedFast(.{}, std.testing.allocator, input);
        defer fast.deinit(std.testing.allocator);

        var diagnostic: ParseDiagnostic = undefined;
        var general = try parseBorrowedWithDiagnostic(std.testing.allocator, input, .{}, &diagnostic);
        defer general.deinit(std.testing.allocator);

        try expectBorrowedTablesEqual(&general, &fast);
    }
}

test "write rows with quoting" {
    const rows = [_]Row{
        .{ .fields = &.{ "name", "city", "note" } },
        .{ .fields = &.{ "Ada", "New York, NY", "said \"hi\"" } },
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeRows(&output.writer, &rows, .{});
    const bytes = try output.toOwnedSlice();
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualStrings(
        "name,city,note\nAda,\"New York, NY\",\"said \"\"hi\"\"\"\n",
        bytes,
    );
}

test "reject invalid write options" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const rows = [_]Row{.{ .fields = &.{"a"} }};
    try std.testing.expectError(error.InvalidOptions, writeRows(&output.writer, &rows, .{
        .delimiter = '"',
        .quote = '"',
    }));
}

test "round trip custom delimiter" {
    const rows = [_]Row{
        .{ .fields = &.{ "a", "b;c", "d" } },
        .{ .fields = &.{ "1", "2", "3" } },
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeRows(&output.writer, &rows, .{ .delimiter = ';' });
    const bytes = try output.toOwnedSlice();
    defer std.testing.allocator.free(bytes);

    var parsed = try parse(std.testing.allocator, bytes, .{ .delimiter = ';' });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("b;c", parsed.rows[0].fields[1]);
    try std.testing.expectEqualStrings("3", parsed.rows[1].fields[2]);
}
