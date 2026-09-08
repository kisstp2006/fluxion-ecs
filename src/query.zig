// SPDX-License-Identifier: BSD-3-Clause

//! Everything with this set of components, in slices.
//!
//! ```zig
//! const Movement = ecs.Query(.{ Position, Velocity });
//!
//! var it = try Movement.over(&world);
//! while (it.next()) |chunk| {
//!     const at = chunk.slice(Position);
//!     const speed = chunk.slice(Velocity);
//!     for (at, speed) |*p, v| {
//!         p.x += v.x;
//!         p.y += v.y;
//!     }
//! }
//! ```
//!
//! **A query hands out slices, not entities one at a time.** An archetype
//! already stores each component in its own array with the rows lined up, so
//! what a query has to give the caller is those arrays - and then the loop is
//! an ordinary Zig loop over slices, which the compiler vectorises and the
//! processor prefetches. An interface that yielded one entity per call would
//! throw that away and be slower and longer to write.
//!
//! **One chunk is one archetype**, or a piece of one. Every entity in it has
//! the same components, so no branch inside the loop asks whether this one has
//! a `Velocity`: the query already answered that by choosing which archetypes
//! to visit.
//!
//! **Chunks are how this gets onto more than one core.** They do not overlap -
//! no row is in two of them - so handing each to a job is safe without a lock
//! anywhere, and `each` does exactly that. On a target with no threads the
//! same call runs them on the calling thread, so a browser build is the same
//! code taking longer.
//!
//! **Do not change the world inside one.** Spawning, despawning, adding and
//! removing all move rows, and the slices a chunk handed out point at rows.
//! Collect what to change and do it after the loop; `World.despawn` after the
//! iterator is done is the usual shape.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Jobs = @import("fluxion_jobs").Jobs;

const Archetype = @import("Archetype.zig");
const component = @import("component.zig");
const World = @import("World.zig");
const Entity = World.Entity;

/// A query over a set of component types.
///
/// `types` is a tuple of types: `Query(.{ Position, Velocity })`. Every entity
/// that has all of them is visited, whatever else it also has.
pub fn Query(comptime types: anytype) type {
    const fields = @typeInfo(@TypeOf(types)).@"struct".fields;
    comptime {
        if (fields.len == 0) {
            @compileError("fluxion-ecs: a query over nothing matches everything, which is what `World.archetypeSlice` is for");
        }
        for (fields) |field| component.check(@field(types, field.name));
        // The same component twice would hand out two names for one column,
        // and the second `slice` call would be a silent alias.
        for (fields, 0..) |a, i| {
            for (fields[i + 1 ..]) |b| {
                if (@field(types, a.name) == @field(types, b.name)) {
                    @compileError("fluxion-ecs: " ++ @typeName(@field(types, a.name)) ++
                        " appears twice in one query");
                }
            }
        }
    }

    return struct {
        const Self = @This();

        /// How many component types this query asks for.
        pub const arity = fields.len;

        /// The component type at position `i` of the query.
        pub fn TypeAt(comptime i: usize) type {
            return @field(types, fields[i].name);
        }

        /// Where `T` sits in this query, at compile time.
        fn indexOf(comptime T: type) usize {
            comptime {
                for (fields, 0..) |field, i| {
                    if (@field(types, field.name) == T) return i;
                }
                @compileError("fluxion-ecs: " ++ @typeName(T) ++ " is not in this query");
            }
        }

        /// A run of rows that all have these components, from one archetype.
        pub const Chunk = struct {
            /// Which entity is in each row, in the same order as every slice.
            entities: []const Entity,
            /// The first row of each component's column, in query order.
            bases: [arity][*]u8,

            /// How many rows.
            pub fn len(self: Chunk) usize {
                return self.entities.len;
            }

            /// This chunk's values of one component, to read or to write.
            pub fn slice(self: Chunk, comptime T: type) []T {
                const i = comptime indexOf(T);
                const typed: [*]T = @ptrCast(@alignCast(self.bases[i]));
                return typed[0..self.entities.len];
            }

            /// Rows `from` up to `to` of this chunk, as a chunk of their own.
            /// What splitting the work across jobs is made of.
            pub fn part(self: Chunk, from: usize, to: usize) Chunk {
                std.debug.assert(from <= to and to <= self.entities.len);
                var bases: [arity][*]u8 = undefined;
                inline for (0..arity) |i| {
                    bases[i] = self.bases[i] + from * @sizeOf(TypeAt(i));
                }
                return .{ .entities = self.entities[from..to], .bases = bases };
            }
        };

        /// Walks the archetypes that have every component this query wants.
        pub const Iterator = struct {
            world: *World,
            ids: [arity]component.Id,
            at: usize = 0,

            pub fn next(self: *Iterator) ?Chunk {
                const archetypes = self.world.archetypeSlice();
                while (self.at < archetypes.len) {
                    const archetype = &archetypes[self.at];
                    self.at += 1;

                    // An archetype with nothing in it is a shape some entity
                    // had once. Skipping it here keeps the loop body from
                    // having to care.
                    if (archetype.len() == 0) continue;
                    if (!archetype.signature().containsAll(&self.ids)) continue;

                    var bases: [arity][*]u8 = undefined;
                    inline for (0..arity) |i| {
                        bases[i] = archetype.columnOf(self.ids[i]).?.bytes.ptr;
                    }
                    return .{ .entities = archetype.entities.items, .bases = bases };
                }
                return null;
            }

            /// Start again from the first archetype.
            pub fn reset(self: *Iterator) void {
                self.at = 0;
            }
        };

        /// An iterator over `world`.
        ///
        /// Registers any component this query names that the world has not
        /// seen, which is why it can fail and why it takes a mutable world.
        pub fn over(world: *World) World.Error!Iterator {
            var ids: [arity]component.Id = undefined;
            inline for (0..arity) |i| ids[i] = try world.idOf(TypeAt(i));
            return .{ .world = world, .ids = ids };
        }

        /// How many entities this query matches. One pass over the
        /// archetypes, no pass over the rows.
        pub fn count(world: *World) World.Error!usize {
            var it = try over(world);
            var total: usize = 0;
            while (it.next()) |chunk| total += chunk.len();
            return total;
        }

        /// The first chunk, for a caller that wants the whole thing in one
        /// slice and knows there is only one archetype. Null when nothing
        /// matches.
        pub fn first(world: *World) World.Error!?Chunk {
            var it = try over(world);
            return it.next();
        }

        /// How many rows a job gets at a time, by default.
        ///
        /// Small enough that a handful of archetypes still spread across the
        /// workers, large enough that the copy and the lock per job are lost
        /// in the work. A thousand rows of two components is a few tens of
        /// microseconds, against about a microsecond to hand one out.
        pub const default_grain = 1024;

        pub const Options = struct {
            /// The most rows one job takes.
            grain: usize = default_grain,
        };

        /// Run `function` over every chunk, on `jobs`.
        ///
        /// Chunks do not overlap, so nothing here locks and nothing needs to:
        /// two jobs never hold a pointer to the same row. What `function` must
        /// not do is change the world - see the module comment.
        ///
        /// With a scheduler that has no workers this runs the chunks on the
        /// calling thread, in order, which is what a browser build does and is
        /// the only difference there.
        pub fn each(
            world: *World,
            jobs: *Jobs,
            context: anytype,
            comptime function: fn (@TypeOf(context), Chunk) void,
            options: Options,
        ) (World.Error || Allocator.Error)!void {
            const grain = @max(options.grain, 1);

            // The chunks are kept because a job takes a pointer to one: the
            // payload a scheduler copies is small on purpose, and a `Chunk`
            // of several components would not fit in it.
            var pieces: std.ArrayListUnmanaged(Chunk) = .empty;
            defer pieces.deinit(world.gpa);

            var it = try over(world);
            while (it.next()) |chunk| {
                var from: usize = 0;
                while (from < chunk.len()) {
                    const to = @min(from + grain, chunk.len());
                    try pieces.append(world.gpa, chunk.part(from, to));
                    from = to;
                }
            }

            const Shim = struct {
                fn run(ctx: @TypeOf(context), piece: *const Chunk) void {
                    function(ctx, piece.*);
                }
            };
            for (pieces.items) |*piece| {
                // A scheduler with no room left is not a failure: the work
                // happens here instead, which is what one with no workers
                // does with all of it.
                _ = jobs.spawn(Shim.run, .{ context, piece }) catch Shim.run(context, piece);
            }
            jobs.waitAll();
        }
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { points: u16 };

test "a query visits everything with the components and nothing else" {
    var world: World = .init(testing.allocator);
    defer world.deinit();

    const moving = try world.spawnWith(.{ Position{ .x = 0, .y = 0 }, Velocity{ .x = 1, .y = 2 } });
    _ = try world.spawnWith(.{Position{ .x = 5, .y = 5 }});
    const both_and_more = try world.spawnWith(.{
        Position{ .x = 10, .y = 10 },
        Velocity{ .x = -1, .y = 0 },
        Health{ .points = 3 },
    });

    const Movement = Query(.{ Position, Velocity });
    try testing.expectEqual(@as(usize, 2), try Movement.count(&world));

    var seen: usize = 0;
    var it = try Movement.over(&world);
    while (it.next()) |chunk| {
        const at = chunk.slice(Position);
        const speed = chunk.slice(Velocity);
        try testing.expectEqual(chunk.len(), at.len);
        for (at, speed, chunk.entities) |*p, v, e| {
            p.x += v.x;
            seen += 1;
            try testing.expect(e.eql(moving) or e.eql(both_and_more));
        }
    }
    try testing.expectEqual(@as(usize, 2), seen);

    // The writes went into the world, and the entity with no velocity was
    // not touched.
    try testing.expectEqual(@as(f32, 1), world.get(moving, Position).?.x);
    try testing.expectEqual(@as(f32, 9), world.get(both_and_more, Position).?.x);
}

test "a query over a world with nothing in it is an empty loop" {
    var world: World = .init(testing.allocator);
    defer world.deinit();

    const Movement = Query(.{ Position, Velocity });
    try testing.expectEqual(@as(usize, 0), try Movement.count(&world));
    try testing.expectEqual(@as(?Query(.{ Position, Velocity }).Chunk, null), try Movement.first(&world));

    // Asking registered the components; asking again does not register them
    // twice.
    const registered = world.componentCount();
    _ = try Movement.count(&world);
    try testing.expectEqual(registered, world.componentCount());
}

test "a chunk splits into parts that cover it exactly once" {
    var world: World = .init(testing.allocator);
    defer world.deinit();

    for (0..10) |i| {
        _ = try world.spawnWith(.{Position{ .x = @floatFromInt(i), .y = 0 }});
    }

    const Places = Query(.{Position});
    const whole = (try Places.first(&world)).?;
    try testing.expectEqual(@as(usize, 10), whole.len());

    var covered: usize = 0;
    var total: f32 = 0;
    var from: usize = 0;
    while (from < whole.len()) {
        const to = @min(from + 3, whole.len());
        const part = whole.part(from, to);
        try testing.expectEqual(to - from, part.len());
        for (part.slice(Position)) |p| {
            total += p.x;
            covered += 1;
        }
        from = to;
    }
    try testing.expectEqual(@as(usize, 10), covered);
    // 0+1+...+9
    try testing.expectEqual(@as(f32, 45), total);
}
