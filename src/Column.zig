// SPDX-License-Identifier: BSD-3-Clause

//! One component type's values for one archetype, as bytes.
//!
//! A column does not know what it holds. It has a stride, an alignment and a
//! count, and every operation on it is a `memcpy` - which is the whole reason
//! `component.check` refuses anything that owns memory. Nothing here runs a
//! destructor, because there is nothing that could need one.
//!
//! **Removing is a swap with the last.** Rows have no order that anything
//! depends on, so taking one out moves the last row into the hole rather than
//! shifting everything after it. The entity that was last therefore changes
//! row, which is why `Archetype.remove` reports it: the world has to write the
//! new row into that entity's record.

const std = @import("std");
const Allocator = std.mem.Allocator;

const mem = @import("fluxion_mem");

const Column = @This();

/// The bytes, `capacity * stride` of them, aligned for the component type.
bytes: []u8,
stride: usize,
alignment: mem.Alignment,
len: usize = 0,
capacity: usize = 0,

pub const empty_for = init;

/// A column for a component of this size and alignment, holding nothing yet.
pub fn init(stride: usize, alignment: mem.Alignment) Column {
    std.debug.assert(stride != 0);
    return .{ .bytes = &.{}, .stride = stride, .alignment = alignment };
}

pub fn deinit(self: *Column, gpa: Allocator) void {
    if (self.capacity != 0) gpa.rawFree(self.bytes, self.alignment, @returnAddress());
    self.* = undefined;
}

/// Room for `wanted` rows, growing by doubling.
///
/// Allocated through the raw interface because the alignment is a run-time
/// value here: `gpa.alloc` wants it at compile time, and a column does not
/// know its type.
pub fn ensureCapacity(self: *Column, gpa: Allocator, wanted: usize) Allocator.Error!void {
    if (wanted <= self.capacity) return;

    var capacity = if (self.capacity == 0) @max(wanted, 4) else self.capacity;
    while (capacity < wanted) capacity *|= 2;

    const bytes = gpa.rawAlloc(capacity * self.stride, self.alignment, @returnAddress()) orelse
        return error.OutOfMemory;
    const fresh = bytes[0 .. capacity * self.stride];

    if (self.len != 0) @memcpy(fresh[0 .. self.len * self.stride], self.bytes[0 .. self.len * self.stride]);
    if (self.capacity != 0) gpa.rawFree(self.bytes, self.alignment, @returnAddress());

    self.bytes = fresh;
    self.capacity = capacity;
}

/// The bytes of one row. The caller casts them to the component type it knows
/// this column holds.
pub fn at(self: *const Column, row: usize) [*]u8 {
    std.debug.assert(row < self.len);
    return self.bytes.ptr + row * self.stride;
}

/// Every row, as bytes. What a query hands out after casting.
pub fn slice(self: *const Column) []u8 {
    return self.bytes[0 .. self.len * self.stride];
}

/// Copy one component onto the end. There must be room - `Archetype` reserves
/// it across every column before it writes to any of them, so that a failure
/// leaves no column longer than another.
pub fn append(self: *Column, item: [*]const u8) void {
    std.debug.assert(self.len < self.capacity);
    @memcpy(self.bytes[self.len * self.stride ..][0..self.stride], item[0..self.stride]);
    self.len += 1;
}

/// Copy `count` rows of undefined content onto the end, for a column being
/// filled in place afterwards.
pub fn appendUndefined(self: *Column, count: usize) void {
    std.debug.assert(self.len + count <= self.capacity);
    self.len += count;
}

/// Overwrite one row.
pub fn set(self: *Column, row: usize, item: [*]const u8) void {
    @memcpy(self.at(row)[0..self.stride], item[0..self.stride]);
}

/// Take out one row, moving the last one into its place.
pub fn swapRemove(self: *Column, row: usize) void {
    std.debug.assert(row < self.len);
    const last = self.len - 1;
    if (row != last) @memcpy(self.at(row)[0..self.stride], self.at(last)[0..self.stride]);
    self.len -= 1;
}

/// Forget every row, keeping the memory for the next lot.
pub fn clearRetainingCapacity(self: *Column) void {
    self.len = 0;
}

/// How many bytes this column has asked the allocator for.
pub fn bytesUsed(self: *const Column) usize {
    return self.capacity * self.stride;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

const Point = struct { x: f32, y: f32 };

fn columnOf(comptime T: type) Column {
    return .init(@sizeOf(T), .of(T));
}

fn push(column: *Column, gpa: Allocator, comptime T: type, value: T) !void {
    try column.ensureCapacity(gpa, column.len + 1);
    column.append(@ptrCast(&value));
}

fn read(column: *const Column, comptime T: type, row: usize) T {
    const item: *const T = @ptrCast(@alignCast(column.at(row)));
    return item.*;
}

test "a column keeps what was put in it, in order" {
    var column = columnOf(Point);
    defer column.deinit(testing.allocator);

    for (0..5) |i| {
        try push(&column, testing.allocator, Point, .{ .x = @floatFromInt(i), .y = 0 });
    }
    try testing.expectEqual(@as(usize, 5), column.len);
    for (0..5) |i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i)), read(&column, Point, i).x);
    }
}

test "removing a row moves the last one into the hole" {
    var column = columnOf(Point);
    defer column.deinit(testing.allocator);

    for (0..4) |i| {
        try push(&column, testing.allocator, Point, .{ .x = @floatFromInt(i), .y = 0 });
    }
    // 0 1 2 3, take out 1: 0 3 2
    column.swapRemove(1);
    try testing.expectEqual(@as(usize, 3), column.len);
    try testing.expectEqual(@as(f32, 0), read(&column, Point, 0).x);
    try testing.expectEqual(@as(f32, 3), read(&column, Point, 1).x);
    try testing.expectEqual(@as(f32, 2), read(&column, Point, 2).x);

    // Taking out the last one moves nothing.
    column.swapRemove(2);
    try testing.expectEqual(@as(usize, 2), column.len);
    try testing.expectEqual(@as(f32, 3), read(&column, Point, 1).x);
}

test "growing keeps what was there" {
    var column = columnOf(u64);
    defer column.deinit(testing.allocator);

    for (0..1000) |i| try push(&column, testing.allocator, u64, i);
    try testing.expectEqual(@as(usize, 1000), column.len);
    try testing.expect(column.capacity >= 1000);
    for (0..1000) |i| try testing.expectEqual(i, read(&column, u64, i));
}

test "a column of something that needs alignment gets it" {
    const Wide = struct { value: u128 };
    var column = columnOf(Wide);
    defer column.deinit(testing.allocator);

    try push(&column, testing.allocator, Wide, .{ .value = 1 });
    try push(&column, testing.allocator, Wide, .{ .value = 2 });

    try testing.expect(std.mem.isAligned(@intFromPtr(column.bytes.ptr), @alignOf(u128)));
    // And the reads that alignment makes legal give back what went in.
    try testing.expectEqual(@as(u128, 2), read(&column, Wide, 1).value);
}

test "setting overwrites, clearing keeps the memory" {
    var column = columnOf(Point);
    defer column.deinit(testing.allocator);

    try push(&column, testing.allocator, Point, .{ .x = 1, .y = 1 });
    const replacement: Point = .{ .x = 9, .y = 9 };
    column.set(0, @ptrCast(&replacement));
    try testing.expectEqual(@as(f32, 9), read(&column, Point, 0).x);

    const capacity = column.capacity;
    column.clearRetainingCapacity();
    try testing.expectEqual(@as(usize, 0), column.len);
    try testing.expectEqual(capacity, column.capacity);
}
