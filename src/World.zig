// SPDX-License-Identifier: BSD-3-Clause

//! The world: every entity, and everything they are made of.
//!
//! ```zig
//! var world: World = .init(gpa);
//! defer world.deinit();
//!
//! const ship = try world.spawn();
//! try world.add(ship, Position{ .x = 0, .y = 0 });
//! try world.add(ship, Velocity{ .x = 1, .y = 0 });
//!
//! if (world.get(ship, Position)) |at| at.x += 1;
//! ```
//!
//! **Entities are grouped by what they are made of.** Every entity with
//! exactly the same set of components lives in the same archetype, in the same
//! table, in rows that line up - which is what lets a query hand out plain
//! slices and lets a loop over ten thousand of them touch memory in a straight
//! line.
//!
//! **Adding a component moves the entity.** Its row is copied into the
//! archetype that has the larger set and taken out of the one it was in. That
//! is a handful of `memcpy`s, and it is the price of the layout above. An
//! entity whose shape never changes never pays it.
//!
//! **Nothing here is thread-safe, and that is the point.** A world is changed
//! from one thread; the work that runs on many is the reading and writing of
//! component values inside a query, where each chunk of rows belongs to
//! exactly one job. Spawning from inside a parallel loop would have to lock,
//! and locking is what an ECS is for avoiding. See `query`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const mem = @import("fluxion_mem");

const Archetype = @import("Archetype.zig");
const component = @import("component.zig");
const entity_module = @import("entity.zig");

const World = @This();

pub const Entity = entity_module.Entity;
pub const Record = entity_module.Record;

gpa: Allocator,
entities: entity_module.Table = .empty,
/// One per component type, indexed by `component.Id`.
infos: std.ArrayListUnmanaged(component.Info) = .empty,
/// The id a component type was given, by the address that identifies it.
ids: std.AutoHashMapUnmanaged(component.Key, component.Id) = .empty,
/// Every set of components any entity has had. Index zero is the empty set,
/// where a freshly spawned entity lives.
archetypes: std.ArrayListUnmanaged(Archetype) = .empty,
/// Which archetype holds a given set.
by_signature: std.HashMapUnmanaged(
    []const component.Id,
    u32,
    SignatureContext,
    std.hash_map.default_max_load_percentage,
) = .empty,

pub const Error = error{
    /// More component types than one world may know. See
    /// `component.max_components`.
    TooManyComponents,
} || Allocator.Error;

/// A world with nothing in it. `deinit` gives everything back.
pub fn init(gpa: Allocator) World {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *World) void {
    for (self.archetypes.items) |*archetype| archetype.deinit(self.gpa);
    self.archetypes.deinit(self.gpa);
    self.by_signature.deinit(self.gpa);
    self.infos.deinit(self.gpa);
    self.ids.deinit(self.gpa);
    self.entities.deinit(self.gpa);
    self.* = undefined;
}

// -------------------------------------------------------------------------
// Components
// -------------------------------------------------------------------------

/// The id this world knows `T` by, giving it one if this is the first time.
///
/// Ids are per world and are handed out in the order the types are first seen,
/// so they mean nothing to another process. `component.Info.name` is what a
/// file is keyed on.
pub fn idOf(self: *World, comptime T: type) Error!component.Id {
    component.check(T);
    const key = component.keyOf(T);

    const slot = try self.ids.getOrPut(self.gpa, key);
    if (slot.found_existing) return slot.value_ptr.*;
    errdefer _ = self.ids.remove(key);

    if (self.infos.items.len >= component.max_components) return error.TooManyComponents;
    const id: component.Id = @enumFromInt(self.infos.items.len);
    try self.infos.append(self.gpa, .of(T));
    slot.value_ptr.* = id;
    return id;
}

/// The id `T` already has, or null. For a query that must not change the
/// world just by asking about a component nothing has yet.
pub fn findId(self: *const World, comptime T: type) ?component.Id {
    component.check(T);
    return self.ids.get(component.keyOf(T));
}

/// What this world knows about a component id.
pub fn infoOf(self: *const World, id: component.Id) component.Info {
    return self.infos.items[id.index()];
}

/// How many component types this world has seen.
pub fn componentCount(self: *const World) usize {
    return self.infos.items.len;
}

// -------------------------------------------------------------------------
// Entities
// -------------------------------------------------------------------------

/// A new entity with no components.
pub fn spawn(self: *World) Error!Entity {
    const empty = try self.archetypeOf(&.{});

    // The record has to exist before the row, because the row records the
    // entity - and the row cannot fail once its space is reserved.
    try self.archetypes.items[empty].reserveOne(self.gpa);
    const handle = try self.entities.add(self.gpa, .{ .archetype = empty, .row = 0 });
    const row = self.archetypes.items[empty].appendUndefined(handle);
    self.entities.get(handle).?.row = @intCast(row);
    return handle;
}

/// A new entity with these components, in one step.
///
/// `values` is a tuple of component values: `world.spawnWith(.{ Position{...},
/// Velocity{...} })`. Faster than `spawn` and a chain of `add`, because the
/// entity is put straight into its final archetype rather than moving through
/// one per component.
pub fn spawnWith(self: *World, values: anytype) Error!Entity {
    const Values = @TypeOf(values);
    const fields = @typeInfo(Values).@"struct".fields;

    var ids: [fields.len]component.Id = undefined;
    inline for (fields, 0..) |field, i| ids[i] = try self.idOf(field.type);

    var sorted = ids;
    std.mem.sort(component.Id, &sorted, {}, component.Signature.lessThan);
    for (1..sorted.len) |i| {
        if (sorted[i - 1] == sorted[i]) @panic("fluxion-ecs: the same component twice in one spawn");
    }

    const at = try self.archetypeOf(&sorted);
    const archetype = &self.archetypes.items[at];
    try archetype.reserveOne(self.gpa);

    const handle = try self.entities.add(self.gpa, .{ .archetype = at, .row = 0 });
    const row = archetype.appendUndefined(handle);
    self.entities.get(handle).?.row = @intCast(row);

    inline for (fields, 0..) |field, i| {
        const value = @field(values, field.name);
        archetype.columnOf(ids[i]).?.set(row, @ptrCast(&value));
    }
    return handle;
}

/// A new entity straight in the archetype for `ids`, with every one of its
/// components left undefined.
///
/// For a loader, which is about to write all of them and would otherwise
/// spawn an entity and move it once per component - through an archetype per
/// prefix of the set, none of which anything wanted. `ids` must be sorted and
/// registered. Every component must be written before anything reads one.
pub fn spawnRaw(self: *World, ids: []const component.Id) Error!Entity {
    const at = try self.archetypeOf(ids);
    const archetype = &self.archetypes.items[at];
    try archetype.reserveOne(self.gpa);

    const handle = try self.entities.add(self.gpa, .{ .archetype = at, .row = 0 });
    const row = archetype.appendUndefined(handle);
    self.entities.get(handle).?.row = @intCast(row);
    return handle;
}

/// The bytes of one component of one entity, to write into. Null when the
/// entity is not alive or has no such component.
pub fn cellOf(self: *World, e: Entity, id: component.Id) ?[*]u8 {
    const record = self.entities.get(e) orelse return null;
    return self.archetypes.items[record.archetype].cell(id, record.row);
}

/// Is this entity still alive? False for a handle whose entity has died, and
/// for `Entity.none`.
pub fn isAlive(self: *const World, e: Entity) bool {
    return self.entities.contains(e);
}

/// How many entities are alive.
pub fn count(self: *const World) usize {
    return self.entities.count();
}

/// Take an entity and everything it is made of out of the world.
///
/// A handle to it reads as dead from here on, and the slot it used is given to
/// the next entity with a stepped generation. Despawning something already
/// gone does nothing.
pub fn despawn(self: *World, e: Entity) void {
    const record = (self.entities.get(e) orelse return).*;
    self.removeRow(record);
    _ = self.entities.remove(e);
}

/// Take a row out of its archetype and fix up whoever was moved into it.
fn removeRow(self: *World, record: Record) void {
    const archetype = &self.archetypes.items[record.archetype];
    const removed = archetype.remove(record.row);
    if (removed.moved) |moved| {
        // The last row is now where the removed one was.
        self.entities.get(moved).?.row = record.row;
    }
}

// -------------------------------------------------------------------------
// Components on entities
// -------------------------------------------------------------------------

/// Put `value` on `e`, moving it to the archetype that has this component too.
///
/// An entity that already has this component has it overwritten and does not
/// move. `error.NoSuchEntity` when it is not alive.
pub fn add(self: *World, e: Entity, value: anytype) (Error || error{NoSuchEntity})!void {
    const T = @TypeOf(value);
    const id = try self.idOf(T);

    const record = (self.entities.get(e) orelse return error.NoSuchEntity).*;
    if (self.archetypes.items[record.archetype].columnOf(id)) |column| {
        column.set(record.row, @ptrCast(&value));
        return;
    }

    const moved = try self.moveTo(e, record, id, .adding);
    self.archetypes.items[moved.archetype].columnOf(id).?.set(moved.row, @ptrCast(&value));
}

/// Take a component off `e`. Doing so when it has none does nothing.
pub fn remove(self: *World, e: Entity, comptime T: type) Error!void {
    const id = self.findId(T) orelse return;
    const record = (self.entities.get(e) orelse return).*;
    if (!self.archetypes.items[record.archetype].signature().contains(id)) return;
    _ = try self.moveTo(e, record, id, .removing);
}

/// Does `e` have one of these?
pub fn has(self: *const World, e: Entity, comptime T: type) bool {
    const id = self.findId(T) orelse return false;
    const record = self.entities.getConst(e) orelse return false;
    return self.archetypes.items[record.archetype].signature().contains(id);
}

/// The component on `e`, to read or to write, or null when it has none.
///
/// The pointer is into the archetype's column, so it is good until the next
/// thing that moves rows: an `add`, a `remove`, a `despawn`, or a `spawn` that
/// grows the same archetype. Take the value out rather than holding the
/// pointer across one of those.
pub fn get(self: *World, e: Entity, comptime T: type) ?*T {
    const id = self.findId(T) orelse return null;
    const record = self.entities.get(e) orelse return null;
    const cell = self.archetypes.items[record.archetype].cell(id, record.row) orelse return null;
    return @ptrCast(@alignCast(cell));
}

/// `get`, for a caller that only reads.
pub fn getConst(self: *const World, e: Entity, comptime T: type) ?*const T {
    const id = self.findId(T) orelse return null;
    const record = self.entities.getConst(e) orelse return null;
    const archetype = &self.archetypes.items[record.archetype];
    const column = archetype.columnOfConst(id) orelse return null;
    const bytes = column.bytes.ptr + record.row * column.stride;
    return @ptrCast(@alignCast(bytes));
}

const Direction = enum { adding, removing };

/// Move `e` to the archetype that is its current one plus or minus `id`,
/// carrying every component both archetypes have.
fn moveTo(self: *World, e: Entity, record: Record, id: component.Id, how: Direction) Error!Record {
    const source_ids = self.archetypes.items[record.archetype].ids;

    // The target's set, on the stack: an entity cannot have more components
    // than the world knows about, and that is bounded.
    var buffer: [component.max_components]component.Id = undefined;
    var length: usize = 0;
    for (source_ids) |existing| {
        if (how == .removing and existing == id) continue;
        buffer[length] = existing;
        length += 1;
    }
    if (how == .adding) {
        buffer[length] = id;
        length += 1;
        std.mem.sort(component.Id, buffer[0..length], {}, component.Signature.lessThan);
    }

    const target_at = try self.archetypeOf(buffer[0..length]);
    const target = &self.archetypes.items[target_at];
    try target.reserveOne(self.gpa);

    // Nothing below here can fail, so the two tables cannot be left
    // disagreeing about where this entity is.
    const row = target.appendUndefined(e);
    const source = &self.archetypes.items[record.archetype];
    for (source.ids, source.columns) |source_id, *column| {
        if (how == .removing and source_id == id) continue;
        target.columnOf(source_id).?.set(row, column.at(record.row));
    }

    self.removeRow(record);
    const updated: Record = .{ .archetype = target_at, .row = @intCast(row) };
    self.entities.get(e).?.* = updated;
    return updated;
}

// -------------------------------------------------------------------------
// Archetypes
// -------------------------------------------------------------------------

/// The archetype for this set of ids, making it if there is not one yet.
/// `ids` must be sorted.
pub fn archetypeOf(self: *World, ids: []const component.Id) Error!u32 {
    if (self.by_signature.get(ids)) |at| return at;

    const at: u32 = @intCast(self.archetypes.items.len);
    var archetype: Archetype = try .init(self.gpa, ids, self.infos.items);
    errdefer archetype.deinit(self.gpa);

    try self.archetypes.append(self.gpa, archetype);
    errdefer _ = self.archetypes.pop();

    // The key borrows the archetype's own copy of the ids, which lives as
    // long as the archetype does.
    try self.by_signature.put(self.gpa, self.archetypes.items[at].ids, at);
    return at;
}

/// Every archetype in the world, for a query to walk.
pub fn archetypeSlice(self: *World) []Archetype {
    return self.archetypes.items;
}

pub fn archetypeCount(self: *const World) usize {
    return self.archetypes.items.len;
}

const SignatureContext = struct {
    pub fn hash(_: SignatureContext, ids: []const component.Id) u64 {
        const signature: component.Signature = .{ .ids = ids };
        return signature.hash();
    }
    pub fn eql(_: SignatureContext, a: []const component.Id, b: []const component.Id) bool {
        const first: component.Signature = .{ .ids = a };
        return first.eql(.{ .ids = b });
    }
};

// -------------------------------------------------------------------------
// What it costs
// -------------------------------------------------------------------------

/// What the world is holding, for a debug overlay or a log line.
pub const Stats = struct {
    entities: usize,
    archetypes: usize,
    components: usize,
    /// Bytes the columns have asked the allocator for. Not the whole cost -
    /// the entity table and the archetype list are on top - but the part that
    /// grows with the world.
    column_bytes: usize,

    /// Print as `4096 entities in 7 archetypes, 1.2 MiB of columns`.
    pub fn format(self: Stats, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} entities in {d} archetypes, {f} of columns", .{
            self.entities,
            self.archetypes,
            mem.size(self.column_bytes),
        });
    }
};

pub fn stats(self: *const World) Stats {
    var column_bytes: usize = 0;
    for (self.archetypes.items) |archetype| column_bytes += archetype.bytesUsed();
    return .{
        .entities = self.entities.count(),
        .archetypes = self.archetypes.items.len,
        .components = self.infos.items.len,
        .column_bytes = column_bytes,
    };
}
