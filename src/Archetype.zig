// SPDX-License-Identifier: BSD-3-Clause

//! Every entity that has exactly this set of components.
//!
//! An archetype is a table: one row per entity, one column per component, and
//! the rows of every column line up. An entity's row is the same number in all
//! of them, so a query that wants `Position` and `Velocity` gets two slices
//! that can be walked side by side with no lookups in between. That is the
//! whole reason for organising a world this way.
//!
//! **The set is the identity.** Adding a component to an entity does not
//! change its archetype; it moves the entity to the archetype that has the
//! larger set, copying its row across. Entities that live and die without
//! changing shape - which is most of them - never move at all.
//!
//! **Rows have no order.** Removing one swaps the last into its place, so a
//! removal is a few `memcpy`s rather than a shift of everything after it. The
//! entity that was last therefore changes row, and `remove` says so.

const std = @import("std");
const Allocator = std.mem.Allocator;

const component = @import("component.zig");
const Column = @import("Column.zig");
const Entity = @import("entity.zig").Entity;

const Archetype = @This();

/// The component ids in this archetype, sorted. Owned.
ids: []component.Id,
/// One column per id, in the same order.
columns: []Column,
/// Which entity is in each row.
entities: std.ArrayListUnmanaged(Entity) = .empty,

pub fn init(
    gpa: Allocator,
    ids: []const component.Id,
    infos: []const component.Info,
) Allocator.Error!Archetype {
    const owned_ids = try gpa.dupe(component.Id, ids);
    errdefer gpa.free(owned_ids);

    const columns = try gpa.alloc(Column, ids.len);
    errdefer gpa.free(columns);
    for (columns, ids) |*column, id| {
        const info = infos[id.index()];
        column.* = .init(info.size, info.alignment);
    }

    return .{ .ids = owned_ids, .columns = columns };
}

pub fn deinit(self: *Archetype, gpa: Allocator) void {
    for (self.columns) |*column| column.deinit(gpa);
    gpa.free(self.columns);
    gpa.free(self.ids);
    self.entities.deinit(gpa);
    self.* = undefined;
}

pub fn signature(self: *const Archetype) component.Signature {
    return .{ .ids = self.ids };
}

pub fn len(self: *const Archetype) usize {
    return self.entities.items.len;
}

/// The column holding `id`, or null when this archetype has no such component.
pub fn columnOf(self: *Archetype, id: component.Id) ?*Column {
    const at = self.signature().indexOf(id) orelse return null;
    return &self.columns[at];
}

pub fn columnOfConst(self: *const Archetype, id: component.Id) ?*const Column {
    const at = self.signature().indexOf(id) orelse return null;
    return &self.columns[at];
}

/// Make room for one more row in every column, so that adding one cannot fail
/// part of the way through and leave the columns disagreeing about how many
/// rows there are.
pub fn reserveOne(self: *Archetype, gpa: Allocator) Allocator.Error!void {
    try self.entities.ensureUnusedCapacity(gpa, 1);
    for (self.columns) |*column| {
        try column.ensureCapacity(gpa, self.len() + 1);
    }
}

/// Add a row for `entity` with its components undefined, and return the row.
/// `reserveOne` must have been called.
pub fn appendUndefined(self: *Archetype, entity: Entity) usize {
    const row = self.len();
    self.entities.appendAssumeCapacity(entity);
    for (self.columns) |*column| column.appendUndefined(1);
    return row;
}

/// Which entity had to move to fill the hole, and where it was.
pub const Removed = struct {
    /// The entity now living at the removed row, when one was moved there.
    moved: ?Entity,
};

/// Take one row out, moving the last row into its place.
pub fn remove(self: *Archetype, row: usize) Removed {
    std.debug.assert(row < self.len());
    const last = self.len() - 1;
    const moved: ?Entity = if (row != last) self.entities.items[last] else null;

    for (self.columns) |*column| column.swapRemove(row);
    _ = self.entities.swapRemove(row);
    return .{ .moved = moved };
}

/// The bytes of one component of one row.
pub fn cell(self: *Archetype, id: component.Id, row: usize) ?[*]u8 {
    const column = self.columnOf(id) orelse return null;
    return column.at(row);
}

/// How many bytes this archetype has asked the allocator for, columns only.
pub fn bytesUsed(self: *const Archetype) usize {
    var total: usize = 0;
    for (self.columns) |column| total += column.bytesUsed();
    return total;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

const Position = struct { x: f32, y: f32 };
const Health = struct { points: u16 };

/// A registry of two components, as the world would hand one over.
fn twoInfos() [2]component.Info {
    return .{ component.Info.of(Position), component.Info.of(Health) };
}

const position_id: component.Id = @enumFromInt(0);
const health_id: component.Id = @enumFromInt(1);

fn put(archetype: *Archetype, gpa: Allocator, entity: Entity, at: Position, hp: Health) !usize {
    try archetype.reserveOne(gpa);
    const row = archetype.appendUndefined(entity);
    archetype.columnOf(position_id).?.set(row, @ptrCast(&at));
    archetype.columnOf(health_id).?.set(row, @ptrCast(&hp));
    return row;
}

fn positionAt(archetype: *Archetype, row: usize) Position {
    const item: *const Position = @ptrCast(@alignCast(archetype.cell(position_id, row).?));
    return item.*;
}

test "an archetype is a table whose columns line up" {
    const infos = twoInfos();
    var archetype: Archetype = try .init(testing.allocator, &.{ position_id, health_id }, &infos);
    defer archetype.deinit(testing.allocator);

    for (0..3) |i| {
        const e: Entity = .{ .index = @intCast(i), .generation = 1 };
        const row = try put(&archetype, testing.allocator, e, .{ .x = @floatFromInt(i), .y = 0 }, .{ .points = @intCast(i * 10) });
        try testing.expectEqual(i, row);
    }

    try testing.expectEqual(@as(usize, 3), archetype.len());
    for (0..3) |i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i)), positionAt(&archetype, i).x);
        try testing.expectEqual(@as(u32, @intCast(i)), archetype.entities.items[i].index);
    }
}

test "removing a row says which entity moved to fill it" {
    const infos = twoInfos();
    var archetype: Archetype = try .init(testing.allocator, &.{ position_id, health_id }, &infos);
    defer archetype.deinit(testing.allocator);

    for (0..3) |i| {
        const e: Entity = .{ .index = @intCast(i), .generation = 1 };
        _ = try put(&archetype, testing.allocator, e, .{ .x = @floatFromInt(i), .y = 0 }, .{ .points = 1 });
    }

    // Take out the first: the last moves into row zero, in every column.
    const removed = archetype.remove(0);
    try testing.expectEqual(@as(u32, 2), removed.moved.?.index);
    try testing.expectEqual(@as(usize, 2), archetype.len());
    try testing.expectEqual(@as(f32, 2), positionAt(&archetype, 0).x);
    try testing.expectEqual(@as(u32, 2), archetype.entities.items[0].index);

    // Taking out the last moves nobody.
    const last = archetype.remove(1);
    try testing.expectEqual(@as(?Entity, null), last.moved);
    try testing.expectEqual(@as(usize, 1), archetype.len());
}

test "an archetype knows only its own components" {
    const infos = twoInfos();
    var archetype: Archetype = try .init(testing.allocator, &.{position_id}, &infos);
    defer archetype.deinit(testing.allocator);

    try testing.expect(archetype.columnOf(position_id) != null);
    try testing.expect(archetype.columnOf(health_id) == null);
    try testing.expect(archetype.signature().contains(position_id));
    try testing.expect(!archetype.signature().contains(health_id));
}

test "an archetype with no components still holds entities" {
    // What a bare `spawn` produces, before anything is added to it.
    const infos = twoInfos();
    var archetype: Archetype = try .init(testing.allocator, &.{}, &infos);
    defer archetype.deinit(testing.allocator);

    try archetype.reserveOne(testing.allocator);
    const row = archetype.appendUndefined(.{ .index = 7, .generation = 1 });
    try testing.expectEqual(@as(usize, 0), row);
    try testing.expectEqual(@as(usize, 1), archetype.len());
    try testing.expectEqual(@as(usize, 0), archetype.bytesUsed());
}
