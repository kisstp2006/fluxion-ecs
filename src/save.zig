// SPDX-License-Identifier: BSD-3-Clause

//! A world, written down and read back.
//!
//! ```zig
//! const bytes = try ecs.save.encodeAlloc(gpa, &world);
//! defer gpa.free(bytes);
//!
//! var loaded: World = .init(gpa);
//! defer loaded.deinit();
//! try ecs.save.decode(&loaded, bytes, .{ Position, Velocity, Health });
//! ```
//!
//! ```
//! FXWD              four bytes, so a file that is not one is noticed at once
//! version           one byte: the container's own
//! flags, padding    three bytes of zero
//! components        how many, then each one's name and schema fingerprint
//! shapes            every archetype: its components, and which entities are
//!                   in which row
//! values            every archetype's columns, in the same order
//! ```
//!
//! **The shapes come before the values, and that is what makes loading one
//! pass.** Every entity in the file exists before the first component is read,
//! so a component holding a reference to an entity in the last archetype can
//! be rewritten while reading the first. Putting the values first would mean
//! either reading the file twice or being unable to step over a component
//! whose length is only known by parsing it.
//!
//! **Components go through `fluxion-data`, not through `memcpy`.** Writing the
//! columns as they sit in memory would be quicker and would make a save only
//! the machine that wrote it can read: padding, endianness and field order are
//! the compiler's business. Each value is written by its own type's encoder
//! instead, so a world saved on a laptop opens on a phone.
//!
//! **A component is found by name and checked by fingerprint.** The name is
//! `@typeName(T)`, which is stable across runs; the fingerprint says whether
//! the fields are still what they were. A file whose `Position` has grown a
//! `z` is refused rather than read as something it is not.
//!
//! **Entities come back as different entities, and references still work.**
//! A handle cannot be reproduced exactly - its generation counts how many
//! things have lived in a slot, and a fresh world has had none - so loading
//! mints new ones and rewrites every `Entity` stored inside a component to
//! match. That walk is generated per component type at compile time, so an
//! entity three structs deep inside a component is rewritten too, and a
//! component with none costs nothing at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const data = @import("fluxion_data");

const component = @import("component.zig");
const World = @import("World.zig");
const Entity = World.Entity;

/// The four bytes every world file starts with.
pub const magic = [4]u8{ 'F', 'X', 'W', 'D' };

/// The container's own version, which is not any component's schema.
pub const format_version: u8 = 1;

/// Magic, version, flags, and two bytes that keep what follows aligned.
pub const header_size = 8;

pub const Error = error{
    /// The first four bytes are not this format's.
    NotAWorld,
    /// A container version this build does not know how to frame.
    UnsupportedVersion,
    /// A component in the file has the name of one this build knows and a
    /// different shape.
    ComponentChanged,
    /// A component in the file that this build does not have. Its values
    /// cannot be stepped over without knowing how long they are.
    UnknownComponent,
    /// The file says something that cannot be true of itself: an index past
    /// the end of its own component list, a row naming an entity it never
    /// wrote.
    Corrupt,
} || data.read.Error || World.Error;

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// Write `world` into `w`.
pub fn encode(w: *Io.Writer, world: *World) (Io.Writer.Error || Allocator.Error)!void {
    try w.writeAll(&magic);
    try w.writeByte(format_version);
    try w.writeAll(&[_]u8{ 0, 0, 0 });

    // The components, in this world's own order, so an archetype names them
    // by index rather than by spelling each name again.
    try data.write.length(w, world.componentCount());
    for (world.infos.items) |info| {
        try data.write.length(w, info.name.len);
        try w.writeAll(info.name);
        try w.writeInt(u64, info.fingerprint, .little);
    }

    // Only archetypes holding something. An empty one is a shape some entity
    // had once, and nothing is lost by forgetting it.
    var live: usize = 0;
    for (world.archetypes.items) |archetype| {
        if (archetype.len() != 0) live += 1;
    }

    // --- the shapes -----------------------------------------------------

    try data.write.length(w, live);
    for (world.archetypes.items) |*archetype| {
        if (archetype.len() == 0) continue;

        try data.write.length(w, archetype.ids.len);
        for (archetype.ids) |id| try data.write.length(w, id.index());

        try data.write.length(w, archetype.len());
        for (archetype.entities.items) |e| {
            try w.writeInt(u32, e.index, .little);
            try w.writeInt(u32, e.generation, .little);
        }
    }

    // --- the values -----------------------------------------------------

    for (world.archetypes.items) |*archetype| {
        if (archetype.len() == 0) continue;
        // Column by column, so one component's rows are together and the
        // reader can walk a column without seeking.
        for (archetype.ids, archetype.columns) |id, column| {
            const info = world.infoOf(id);
            for (0..archetype.len()) |row| {
                try info.write(w, column.bytes.ptr + row * column.stride);
            }
        }
    }
}

/// Write `world` into fresh memory. The caller frees it.
pub fn encodeAlloc(gpa: Allocator, world: *World) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    encode(&out.writer, world) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

/// Which component in the file is which component here.
const Match = struct { id: component.Id };

/// One archetype as the file describes it.
const Shape = struct {
    /// Indices into the file's own component list, in the order the values
    /// were written.
    ids: []u32,
    /// The entities of each row, already minted in this world.
    entities: []Entity,
};

/// Read a world out of `bytes` into `world`, which should be empty.
///
/// `known` is the tuple of component types this build understands:
/// `.{ Position, Velocity, Health }`. Every component in the file has to be in
/// it: a value whose type is unknown cannot even be stepped over, because how
/// long it is depends on what it is.
pub fn decode(world: *World, bytes: []const u8, comptime known: anytype) Error!void {
    if (bytes.len < header_size) return error.NotAWorld;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.NotAWorld;
    if (bytes[4] != format_version) return error.UnsupportedVersion;

    const gpa = world.gpa;
    var cursor: data.read.Cursor = .{ .bytes = bytes[header_size..] };

    // --- what the file calls its components -----------------------------

    const named = try cursor.number(u32);
    const matches = try gpa.alloc(Match, named);
    defer gpa.free(matches);

    for (matches) |*slot| {
        const length = try cursor.number(u32);
        const name = try cursor.take(length);
        const fingerprint = std.mem.readInt(u64, (try cursor.take(8))[0..8], .little);
        slot.* = try match(world, name, fingerprint, known);
    }

    // --- the shapes, and an entity for every row ------------------------

    const archetype_count = try cursor.number(u32);
    const shapes = try gpa.alloc(Shape, archetype_count);
    var built: usize = 0;
    defer {
        for (shapes[0..built]) |shape| {
            gpa.free(shape.ids);
            gpa.free(shape.entities);
        }
        gpa.free(shapes);
    }

    var remap: std.AutoHashMapUnmanaged(u64, Entity) = .empty;
    defer remap.deinit(gpa);

    while (built < archetype_count) : (built += 1) {
        const id_count = try cursor.number(u32);
        const ids = try gpa.alloc(u32, id_count);
        errdefer gpa.free(ids);
        for (ids) |*id| {
            id.* = try cursor.number(u32);
            if (id.* >= matches.len) return error.Corrupt;
        }

        // The shape this archetype has in *this* world, sorted, so every
        // entity of it goes straight into its final table.
        const here = try gpa.alloc(component.Id, id_count);
        defer gpa.free(here);
        for (here, ids) |*id, file_id| id.* = matches[file_id].id;
        std.mem.sort(component.Id, here, {}, component.Signature.lessThan);
        for (1..here.len) |i| {
            if (here[i - 1] == here[i]) return error.Corrupt;
        }

        const rows = try cursor.number(u32);
        const entities = try gpa.alloc(Entity, rows);
        errdefer gpa.free(entities);
        for (entities) |*e| {
            const index = std.mem.readInt(u32, (try cursor.take(4))[0..4], .little);
            const generation = std.mem.readInt(u32, (try cursor.take(4))[0..4], .little);
            const was: Entity = .{ .index = index, .generation = generation };
            e.* = try world.spawnRaw(here);
            try remap.put(gpa, was.toInt(), e.*);
        }

        shapes[built] = .{ .ids = ids, .entities = entities };
    }

    // --- the values -----------------------------------------------------

    for (shapes[0..built]) |shape| {
        for (shape.ids) |file_id| {
            const id = matches[file_id].id;
            const info = world.infoOf(id);
            for (shape.entities) |e| {
                // Straight into the column: the row is already there, so
                // there is no value on the stack and no second copy.
                const cell = world.cellOf(e, id) orelse return error.Corrupt;
                try info.read(&cursor, cell);
                info.remap(cell, &remap);
            }
        }
    }
}

/// Find the component this build knows by that name, and check its shape.
fn match(world: *World, name: []const u8, fingerprint: u64, comptime known: anytype) Error!Match {
    const fields = @typeInfo(@TypeOf(known)).@"struct".fields;
    inline for (fields) |field| {
        const T = @field(known, field.name);
        if (std.mem.eql(u8, name, @typeName(T))) {
            if (fingerprint != data.fingerprintOf(T)) return error.ComponentChanged;
            return .{ .id = try world.idOf(T) };
        }
    }
    return error.UnknownComponent;
}

/// An allocator that refuses. A component cannot need one - `component.check`
/// refuses every type that would.
const failing: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = struct {
            fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
                return null;
            }
        }.alloc,
        .resize = struct {
            fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
                return false;
            }
        }.resize,
        .remap = struct {
            fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
                return null;
            }
        }.remap,
        .free = struct {
            fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
        }.free,
    },
};
