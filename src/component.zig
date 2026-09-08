// SPDX-License-Identifier: BSD-3-Clause

//! What a component is allowed to be, and what the world remembers about one.
//!
//! **A component is plain data.** No pointers, no slices, nothing that owns
//! anything. That is not a simplification to be lifted later - it is what
//! makes the rest of this work. Columns can be `memcpy`d, a row can be moved
//! between archetypes by copying bytes, removing one is a swap with the last,
//! and a world can be written to a file and read back on another machine.
//! Every one of those stops being true the moment a component holds a pointer.
//!
//! The rule is checked at compile time, by `fluxion-data`: `schema.check`
//! refuses the things no format can carry, and `schema.allocates` is exactly
//! the question "does reading one of these need an allocator", which for a
//! component must be no. Text in a component is an id into a table of text.
//!
//! **Identity is the type, and it has two names.** At run time a component is
//! a `component.Id`, an index into the world's registry, handed out the first
//! time that type is seen. In a file it is `@typeName(T)` and the schema
//! fingerprint, because an index means nothing to the next process. Two types
//! with the same fields - `Position` and `Velocity`, both two floats - have
//! the same fingerprint and different names, which is why the name is what a
//! save is keyed on and the fingerprint only says whether the layout moved.

const std = @import("std");
const Io = std.Io;

const data = @import("fluxion_data");
const mem = @import("fluxion_mem");

const Entity = @import("entity.zig").Entity;

/// What a loader uses to turn a saved entity into the one it minted.
pub const Remap = std.AutoHashMapUnmanaged(u64, Entity);

/// Which component, inside one world. Not stable across runs, and not
/// meaningful in a file - see `Info.name`.
pub const Id = enum(u16) {
    _,

    pub fn index(self: Id) usize {
        return @intFromEnum(self);
    }
};

/// The most component types one world may know.
pub const max_components = 1024;

/// Refuse, at compile time, everything a component may not be.
pub fn check(comptime T: type) void {
    comptime {
        data.schema.check(T);
        if (data.schema.allocates(T)) {
            @compileError("fluxion-ecs: " ++ @typeName(T) ++
                " has a slice in it, so it owns memory, so it is not a component." ++
                " Put the bytes somewhere the world can see and hold an index to them.");
        }
        if (@sizeOf(T) == 0) {
            // A tag with no data is a real thing to want, and this is not the
            // release that has it: an empty column would need a column that
            // stores nothing, and every loop here assumes a stride.
            @compileError("fluxion-ecs: " ++ @typeName(T) ++
                " has no fields, and zero-sized components are not supported yet." ++
                " Give it a field, or keep the set somewhere else.");
        }
        if (@sizeOf(T) > max_component_size) {
            @compileError("fluxion-ecs: " ++ @typeName(T) ++ " is larger than " ++
                std.fmt.comptimePrint("{d}", .{max_component_size}) ++
                " bytes; hold it once and put a handle in the component.");
        }
    }
}

/// The largest a single component may be. Not a hard limit of anything here -
/// a bound that catches a struct that was meant to be pointed at.
pub const max_component_size = 4096;

/// A unique address per component type, which is how the registry recognises
/// a type it has already seen without hashing its name.
pub const Key = *const anyopaque;

pub fn keyOf(comptime T: type) Key {
    // A struct declared here is a different struct for every `T`, so its
    // static has a different address for every `T`.
    const Holder = struct {
        const Marker = T;
        var byte: u8 = 0;
    };
    return &Holder.byte;
}

/// What the world remembers about one component type.
///
/// Everything here is derived from the type at compile time and stored so the
/// rest of the library can work without it: a column moves bytes and does not
/// care what they mean, and a save calls through `write` and `read` rather
/// than knowing every type in the program.
pub const Info = struct {
    /// `@typeName(T)`. Unique within a program, and stable across runs, which
    /// is what a file needs.
    name: []const u8,
    /// The schema fingerprint from `fluxion-data`. Says whether the layout of
    /// this type is the one a file was written with.
    fingerprint: u64,
    size: usize,
    alignment: mem.Alignment,

    /// Write one value of this type into `w`, portably.
    write: *const fn (w: *Io.Writer, item: *const anyopaque) Io.Writer.Error!void,
    /// Read one back over `item`, which must have room for `size` bytes.
    read: *const fn (cursor: *data.read.Cursor, item: *anyopaque) ReadError!void,
    /// Rewrite every `Entity` inside one value, wherever it sits. Generated
    /// per type: a component with no entity in it compiles to nothing.
    remap: *const fn (item: *anyopaque, map: *const Remap) void,

    pub const ReadError = data.read.Error;

    pub fn of(comptime T: type) Info {
        check(T);
        const Shim = struct {
            fn write(w: *Io.Writer, item: *const anyopaque) Io.Writer.Error!void {
                const typed: *const T = @ptrCast(@alignCast(item));
                return data.write.value(w, T, typed.*);
            }
            fn read(cursor: *data.read.Cursor, item: *anyopaque) ReadError!void {
                const typed: *T = @ptrCast(@alignCast(item));
                // No allocator is needed and none is reachable: `check` has
                // already refused every type that would ask for one.
                typed.* = try data.read.value(T, cursor, failing);
            }
            fn remap(item: *anyopaque, map: *const Remap) void {
                const typed: *T = @ptrCast(@alignCast(item));
                remapEntities(T, typed, map);
            }
        };
        return .{
            .name = @typeName(T),
            .fingerprint = data.fingerprintOf(T),
            .size = @sizeOf(T),
            .alignment = .of(T),
            .write = Shim.write,
            .read = Shim.read,
            .remap = Shim.remap,
        };
    }
};

/// Rewrite every `Entity` inside a value, wherever it is.
///
/// Walked at compile time, so a component with no entity in it costs nothing
/// at all. An entity the file did not write becomes `none` rather than a
/// handle to whatever holds that slot now.
pub fn remapEntities(comptime T: type, value: *T, map: *const Remap) void {
    if (T == Entity) {
        if (value.isNone()) return;
        value.* = map.get(value.toInt()) orelse .none;
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            remapEntities(field.type, &@field(value, field.name), map);
        },
        .array => |info| for (value) |*item| remapEntities(info.child, item, map),
        .optional => |info| if (value.*) |*inner| remapEntities(info.child, inner, map),
        .@"union" => switch (value.*) {
            inline else => |*payload| remapEntities(@TypeOf(payload.*), payload, map),
        },
        else => {},
    }
}

/// An allocator that refuses. Reading a component never reaches it, because a
/// component that would ask is a compile error; if one ever did, failing is
/// better than quietly allocating memory nothing will free.
const failing: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = struct {
            fn alloc(_: *anyopaque, _: usize, _: mem.Alignment, _: usize) ?[*]u8 {
                return null;
            }
        }.alloc,
        .resize = struct {
            fn resize(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize, _: usize) bool {
                return false;
            }
        }.resize,
        .remap = struct {
            fn remap(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize, _: usize) ?[*]u8 {
                return null;
            }
        }.remap,
        .free = struct {
            fn free(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize) void {}
        }.free,
    },
};

/// A set of component ids, sorted, which is what names an archetype.
///
/// Sorted so that two entities with the same components have the same
/// signature whatever order they were given in, and so that finding a
/// component in an archetype is a binary search rather than a scan.
pub const Signature = struct {
    ids: []const Id,

    pub fn contains(self: Signature, id: Id) bool {
        return self.indexOf(id) != null;
    }

    pub fn indexOf(self: Signature, id: Id) ?usize {
        var low: usize = 0;
        var high: usize = self.ids.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const at = @intFromEnum(self.ids[middle]);
            const want = @intFromEnum(id);
            if (at < want) {
                low = middle + 1;
            } else if (at > want) {
                high = middle;
            } else return middle;
        }
        return null;
    }

    /// Does this archetype have everything the query asks for?
    pub fn containsAll(self: Signature, wanted: []const Id) bool {
        for (wanted) |id| {
            if (!self.contains(id)) return false;
        }
        return true;
    }

    pub fn eql(self: Signature, other: Signature) bool {
        if (self.ids.len != other.ids.len) return false;
        for (self.ids, other.ids) |a, b| {
            if (a != b) return false;
        }
        return true;
    }

    /// A number for the whole set, for finding an archetype without comparing
    /// every signature in the world.
    pub fn hash(self: Signature) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (self.ids) |id| {
            h ^= @intFromEnum(id);
            h *%= 0x100000001b3;
        }
        return h;
    }

    pub fn lessThan(_: void, a: Id, b: Id) bool {
        return @intFromEnum(a) < @intFromEnum(b);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { points: u16, regenerating: bool };

test "a type is its own key, and no other type's" {
    try testing.expect(keyOf(Position) == keyOf(Position));
    try testing.expect(keyOf(Position) != keyOf(Velocity));
    try testing.expect(keyOf(Position) != keyOf(Health));
    try testing.expect(keyOf(u32) != keyOf(i32));
}

test "what the world remembers about a component" {
    const info: Info = .of(Position);
    try testing.expectEqual(@sizeOf(Position), info.size);
    try testing.expectEqual(mem.Alignment.of(Position), info.alignment);
    try testing.expect(std.mem.endsWith(u8, info.name, "Position"));

    // Two types with the same fields describe the same way, which is why a
    // save is keyed on the name and not on this number.
    try testing.expectEqual(data.fingerprintOf(Velocity), info.fingerprint);
    try testing.expect(!std.mem.eql(u8, info.name, Info.of(Velocity).name));
}

test "a component goes out and comes back the same" {
    const info: Info = .of(Health);

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const written: Health = .{ .points = 4096, .regenerating = true };
    try info.write(&out.writer, &written);

    var cursor: data.read.Cursor = .{ .bytes = out.written() };
    var read: Health = undefined;
    try info.read(&cursor, &read);

    try testing.expectEqual(written.points, read.points);
    try testing.expectEqual(written.regenerating, read.regenerating);
    try testing.expectEqual(@as(usize, 0), cursor.remaining());
}

test "a signature is a sorted set, searched rather than scanned" {
    const ids = [_]Id{ @enumFromInt(1), @enumFromInt(4), @enumFromInt(9) };
    const signature: Signature = .{ .ids = &ids };

    try testing.expect(signature.contains(@enumFromInt(1)));
    try testing.expect(signature.contains(@enumFromInt(9)));
    try testing.expect(!signature.contains(@enumFromInt(0)));
    try testing.expect(!signature.contains(@enumFromInt(5)));
    try testing.expect(!signature.contains(@enumFromInt(10)));

    try testing.expectEqual(@as(?usize, 1), signature.indexOf(@enumFromInt(4)));
    try testing.expectEqual(@as(?usize, null), signature.indexOf(@enumFromInt(2)));

    try testing.expect(signature.containsAll(&.{ @enumFromInt(1), @enumFromInt(9) }));
    try testing.expect(!signature.containsAll(&.{ @enumFromInt(1), @enumFromInt(2) }));
    try testing.expect(signature.containsAll(&.{}));
}

test "the same set has the same hash whatever else is true of it" {
    const a = [_]Id{ @enumFromInt(1), @enumFromInt(4) };
    const b = [_]Id{ @enumFromInt(1), @enumFromInt(4) };
    const c = [_]Id{ @enumFromInt(4), @enumFromInt(1) };

    const sa: Signature = .{ .ids = &a };
    const sb: Signature = .{ .ids = &b };
    const sc: Signature = .{ .ids = &c };

    try testing.expectEqual(sa.hash(), sb.hash());
    try testing.expect(sa.eql(sb));
    // Order matters to the hash, which is why signatures are kept sorted.
    try testing.expect(!sa.eql(sc));
}
