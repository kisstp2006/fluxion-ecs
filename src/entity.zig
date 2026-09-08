// SPDX-License-Identifier: BSD-3-Clause

//! What names a thing in the world.
//!
//! An `Entity` is a [Fluxion Id](https://github.com/kisstp2006/fluxion-id)
//! handle: eight bytes, an index and a generation. The index says which slot,
//! and the generation says how many things have lived in that slot - so a
//! handle to something that died never comes back to life when the slot is
//! reused, which is the bug this kind of handle exists to stop.
//!
//! It is a value. Copy it, compare it, put it in a hash map, store it in a
//! component, write it to a file. All-zero bytes read as `none`, so a
//! component that was `@memset` to zero holds no entity rather than holding
//! entity zero.

const std = @import("std");
const id = @import("fluxion_id");

/// Where an entity's components are: which archetype, and which row of it.
///
/// This is what the world stores per entity, and what makes `get` a couple of
/// array lookups rather than a search.
pub const Record = struct {
    archetype: u32,
    row: u32,
};

/// The table of live entities. `contains` is `isAlive`, and the generation in
/// each slot is what makes a stale handle answer no.
pub const Table = id.handle.Table(Record);

/// A thing in the world. See the module comment.
pub const Entity = Table.Handle;

/// No entity. Also what all-zero bytes mean.
pub const none: Entity = .none;

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "an entity is eight bytes of value" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Entity));

    const a: Entity = .{ .index = 3, .generation = 1 };
    const b: Entity = .{ .index = 3, .generation = 1 };
    const c: Entity = .{ .index = 3, .generation = 2 };

    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expect(!a.isNone());
    try testing.expect(none.isNone());
}

test "zeroed memory holds no entity" {
    var component: extern struct { owner: Entity, other: u32 } = undefined;
    @memset(std.mem.asBytes(&component), 0);
    try testing.expect(component.owner.isNone());
}

test "a slot reused does not answer to the old handle" {
    var table: Table = .empty;
    defer table.deinit(testing.allocator);

    const first = try table.add(testing.allocator, .{ .archetype = 0, .row = 0 });
    try testing.expect(table.contains(first));

    _ = table.remove(first);
    try testing.expect(!table.contains(first));

    // The next entity takes the same slot and is not the same entity.
    const second = try table.add(testing.allocator, .{ .archetype = 1, .row = 1 });
    try testing.expectEqual(first.index, second.index);
    try testing.expect(!first.eql(second));
    try testing.expect(!table.contains(first));
    try testing.expect(table.contains(second));
}
