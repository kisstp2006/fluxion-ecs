// SPDX-License-Identifier: BSD-3-Clause

//! Fluxion ECS - the world, and everything in it.
//!
//!   `World`      entities, the components on them, and what it costs
//!   `Query`      everything with a set of components, in slices
//!   `save`       a world written down and read back
//!   `component`  what a component is allowed to be
//!   `Archetype`  every entity of one shape, as a table
//!   `Column`     one component's values for one archetype
//!
//! ```zig
//! const ecs = @import("fluxion_ecs");
//!
//! var world: ecs.World = .init(gpa);
//! defer world.deinit();
//!
//! const ship = try world.spawnWith(.{
//!     Position{ .x = 0, .y = 0 },
//!     Velocity{ .x = 1, .y = 0 },
//! });
//!
//! const Movement = ecs.Query(.{ Position, Velocity });
//! try Movement.each(&world, &jobs, delta, step, .{});
//!
//! fn step(delta: f32, chunk: Movement.Chunk) void {
//!     const at = chunk.slice(Position);
//!     const speed = chunk.slice(Velocity);
//!     for (at, speed) |*p, v| p.x += v.x * delta;
//! }
//! ```
//!
//! **Entities are grouped by what they are made of.** Everything with exactly
//! the same set of components lives in one table, in rows that line up, so a
//! query hands out plain Zig slices and the loop over them is an ordinary loop
//! the compiler can vectorise. There is no branch inside it asking whether
//! this one has a velocity: the query answered that by choosing which tables
//! to visit.
//!
//! **A component is plain data.** No pointers, no slices, nothing that owns
//! anything - checked at compile time, with a message naming the type. That is
//! not a restriction waiting to be lifted; it is what lets a row be moved with
//! `memcpy`, a removal be a swap with the last row, and a world be written to
//! a file that opens on a different machine. See `component`.
//!
//! **The work goes on every core, and on none.** `Query.each` hands each chunk
//! of rows to a [Fluxion Jobs](https://github.com/kisstp2006/fluxion-jobs)
//! scheduler. Chunks do not overlap, so no two jobs ever touch the same row
//! and nothing locks. A build for the browser has no threads, so the same call
//! runs the chunks on the calling thread - the same code, taking longer, which
//! is the only difference.
//!
//! **It runs anywhere, because it does nothing.** No files, no clock, no
//! threads of its own, no operating system at all: an allocator and
//! arithmetic. Saving hands you bytes and lets you decide where they go.
//!
//! **Nothing here is thread-safe, and that is the point.** A world is changed
//! from one thread. The work that runs on many is the reading and writing of
//! component values inside a query, where each chunk belongs to exactly one
//! job. Spawning from inside a parallel loop would need a lock, and avoiding
//! locks is what this layout is for.

const std = @import("std");

pub const World = @import("World.zig");
pub const component = @import("component.zig");
pub const Archetype = @import("Archetype.zig");
pub const Column = @import("Column.zig");
pub const save = @import("save.zig");

const entity_module = @import("entity.zig");
const query_module = @import("query.zig");

/// What names a thing in the world: eight bytes, and a generation that makes
/// a handle to something dead answer no. See `entity`.
pub const Entity = entity_module.Entity;

/// No entity. Also what all-zero bytes mean.
pub const none = entity_module.none;

pub const entity = entity_module;
pub const query = query_module;

/// Everything with a set of components. See `query`.
pub const Query = query_module.Query;

/// The scheduler a parallel query runs on, re-exported so a caller need not
/// name the package. See `Query.each`.
pub const Jobs = @import("fluxion_jobs").Jobs;

/// A world with nothing in it. Shorthand for `World.init`.
pub fn init(gpa: std.mem.Allocator) World {
    return .init(gpa);
}

test {
    _ = World;
    _ = component;
    _ = Archetype;
    _ = Column;
    _ = entity_module;
    _ = query_module;
    _ = save;
    _ = @import("ecs_test.zig");
}
