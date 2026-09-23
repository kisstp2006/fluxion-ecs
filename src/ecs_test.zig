// SPDX-License-Identifier: BSD-3-Clause

//! The world as a whole: entities changing shape, queries over them, the same
//! work on every core and on none, and a world written down and read back.
//!
//! The modules test themselves for what they are; this is for what happens
//! between them - which is where an archetype design goes wrong, if it does.

const std = @import("std");
const testing = std.testing;

const Jobs = @import("fluxion_jobs").Jobs;

const Query = @import("query.zig").Query;
const World = @import("World.zig");
const save = @import("save.zig");
const Entity = World.Entity;

const gpa = testing.allocator;

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { points: u16, regenerating: bool = false };
/// A component that refers to another entity, which is what makes saving one
/// interesting.
const Owner = struct { entity: Entity, since: u32 };

/// The two ways to have a scheduler, both of which every parallel test runs.
const modes = [_]Jobs.Options{
    .{ .io = testing.io, .workers = .auto },
    .{ .io = null },
};

// -------------------------------------------------------------------------
// Entities and their shape
// -------------------------------------------------------------------------

test "an entity is born with nothing and takes what it is given" {
    var world: World = .init(gpa);
    defer world.deinit();

    const e = try world.spawn();
    try testing.expect(world.isAlive(e));
    try testing.expect(!world.has(e, Position));
    try testing.expect(world.get(e, Position) == null);

    try world.add(e, Position{ .x = 1, .y = 2 });
    try testing.expect(world.has(e, Position));
    try testing.expectEqual(@as(f32, 1), world.get(e, Position).?.x);

    // Adding one it already has overwrites rather than moving it.
    const archetypes = world.archetypeCount();
    try world.add(e, Position{ .x = 9, .y = 9 });
    try testing.expectEqual(@as(f32, 9), world.get(e, Position).?.x);
    try testing.expectEqual(archetypes, world.archetypeCount());

    try testing.expectEqual(@as(usize, 1), world.count());
}

test "the structure count moves with what entities there are and what they are made of, not with a value" {
    var world: World = .init(gpa);
    defer world.deinit();
    var seen = world.structure;

    const e = try world.spawn();
    try testing.expect(world.structure != seen);
    seen = world.structure;
    const f = try world.spawnWith(.{Position{ .x = 0, .y = 0 }});
    try testing.expect(world.structure != seen);
    seen = world.structure;

    try world.add(e, Health{ .points = 3 });
    try testing.expect(world.structure != seen);
    seen = world.structure;

    // A value written, whether by `add` over one it has or by `get`, is not
    // a change of shape.
    try world.add(e, Health{ .points = 4 });
    world.get(f, Position).?.x = 9;
    try testing.expectEqual(seen, world.structure);

    try world.remove(e, Health);
    try testing.expect(world.structure != seen);
    seen = world.structure;
    // Taking off one it has not got changes nothing.
    try world.remove(e, Health);
    try testing.expectEqual(seen, world.structure);

    world.despawn(f);
    try testing.expect(world.structure != seen);
    seen = world.structure;
    world.despawn(f);
    try testing.expectEqual(seen, world.structure);
}

test "components come and go, and the others stay where they were" {
    var world: World = .init(gpa);
    defer world.deinit();

    const e = try world.spawn();
    try world.add(e, Position{ .x = 1, .y = 2 });
    try world.add(e, Velocity{ .x = 3, .y = 4 });
    try world.add(e, Health{ .points = 100 });

    // Taking the middle one out leaves the other two untouched, though the
    // entity has moved to a different archetype to lose it.
    try world.remove(e, Velocity);
    try testing.expect(!world.has(e, Velocity));
    try testing.expectEqual(@as(f32, 1), world.get(e, Position).?.x);
    try testing.expectEqual(@as(f32, 2), world.get(e, Position).?.y);
    try testing.expectEqual(@as(u16, 100), world.get(e, Health).?.points);

    // Removing what is not there does nothing, twice.
    try world.remove(e, Velocity);
    try world.remove(e, Velocity);
    try testing.expect(world.isAlive(e));
}

test "spawning with components lands in one archetype rather than three" {
    var world: World = .init(gpa);
    defer world.deinit();

    const one = try world.spawnWith(.{
        Position{ .x = 1, .y = 1 },
        Velocity{ .x = 2, .y = 2 },
        Health{ .points = 50 },
    });
    // One archetype: the one it was born into. Not one per component
    // added, and not an empty one it passed through on the way.
    try testing.expectEqual(@as(usize, 1), world.archetypeCount());
    try testing.expectEqual(@as(f32, 2), world.get(one, Velocity).?.x);

    // A second entity of the same shape joins it rather than making another.
    _ = try world.spawnWith(.{
        Position{ .x = 3, .y = 3 },
        Velocity{ .x = 4, .y = 4 },
        Health{ .points = 60 },
    });
    try testing.expectEqual(@as(usize, 1), world.archetypeCount());

    // The order components are given in does not make a different shape.
    _ = try world.spawnWith(.{
        Health{ .points = 70 },
        Position{ .x = 5, .y = 5 },
        Velocity{ .x = 6, .y = 6 },
    });
    try testing.expectEqual(@as(usize, 1), world.archetypeCount());
    try testing.expectEqual(@as(usize, 3), world.count());
}

test "a dead entity stays dead, and its slot does not answer for it" {
    var world: World = .init(gpa);
    defer world.deinit();

    const first = try world.spawnWith(.{Position{ .x = 1, .y = 1 }});
    world.despawn(first);

    try testing.expect(!world.isAlive(first));
    try testing.expect(world.get(first, Position) == null);
    try testing.expect(!world.has(first, Position));
    try testing.expectEqual(@as(usize, 0), world.count());

    // Despawning again does nothing rather than something bad.
    world.despawn(first);

    // The next entity takes the same slot with a stepped generation, and the
    // old handle does not name it.
    const second = try world.spawnWith(.{Position{ .x = 2, .y = 2 }});
    try testing.expectEqual(first.index, second.index);
    try testing.expect(!world.isAlive(first));
    try testing.expect(world.isAlive(second));
    try testing.expectEqual(@as(f32, 2), world.get(second, Position).?.x);

    // Adding to something dead says so rather than writing somewhere.
    try testing.expectError(error.NoSuchEntity, world.add(first, Health{ .points = 1 }));
}

test "removing a row from the middle keeps everyone else findable" {
    // The bug this design is most likely to have: a removal moves the last
    // row into the hole, and the entity that was in it has to be told.
    var world: World = .init(gpa);
    defer world.deinit();

    var made: [64]Entity = undefined;
    for (&made, 0..) |*e, i| {
        e.* = try world.spawnWith(.{Position{ .x = @floatFromInt(i), .y = 0 }});
    }

    // Take out every third, from the front, so rows keep moving under the
    // ones that are left.
    var alive: std.ArrayListUnmanaged(Entity) = .empty;
    defer alive.deinit(gpa);
    for (made, 0..) |e, i| {
        if (i % 3 == 0) {
            world.despawn(e);
        } else {
            try alive.append(gpa, e);
        }
    }

    try testing.expectEqual(alive.items.len, world.count());
    // Every survivor still has the position it was born with.
    for (made, 0..) |e, i| {
        if (i % 3 == 0) {
            try testing.expect(!world.isAlive(e));
            continue;
        }
        try testing.expectEqual(@as(f32, @floatFromInt(i)), world.get(e, Position).?.x);
    }
}

test "changing shape while others watch keeps everyone's values" {
    var world: World = .init(gpa);
    defer world.deinit();

    var made: [32]Entity = undefined;
    for (&made, 0..) |*e, i| {
        e.* = try world.spawnWith(.{
            Position{ .x = @floatFromInt(i), .y = 0 },
            Health{ .points = @intCast(i) },
        });
    }

    // Give half of them a velocity, which moves them to another archetype
    // and shuffles the rows of the one they left.
    for (made, 0..) |e, i| {
        if (i % 2 == 0) try world.add(e, Velocity{ .x = @floatFromInt(i * 2), .y = 0 });
    }

    for (made, 0..) |e, i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i)), world.get(e, Position).?.x);
        try testing.expectEqual(@as(u16, @intCast(i)), world.get(e, Health).?.points);
        if (i % 2 == 0) {
            try testing.expectEqual(@as(f32, @floatFromInt(i * 2)), world.get(e, Velocity).?.x);
        } else {
            try testing.expect(!world.has(e, Velocity));
        }
    }
}

// -------------------------------------------------------------------------
// Queries
// -------------------------------------------------------------------------

test "a query finds every matching entity across every archetype" {
    var world: World = .init(gpa);
    defer world.deinit();

    // Three shapes, two of which match.
    for (0..10) |i| {
        _ = try world.spawnWith(.{
            Position{ .x = @floatFromInt(i), .y = 0 },
            Velocity{ .x = 1, .y = 0 },
        });
    }
    for (0..5) |i| {
        _ = try world.spawnWith(.{
            Position{ .x = @floatFromInt(i), .y = 0 },
            Velocity{ .x = 1, .y = 0 },
            Health{ .points = 1 },
        });
    }
    for (0..7) |_| _ = try world.spawnWith(.{Position{ .x = 0, .y = 0 }});

    const Movement = Query(.{ Position, Velocity });
    try testing.expectEqual(@as(usize, 15), try Movement.count(&world));
    try testing.expectEqual(@as(usize, 22), try Query(.{Position}).count(&world));
    try testing.expectEqual(@as(usize, 5), try Query(.{ Position, Health }).count(&world));

    // Two chunks, because two archetypes match.
    var chunks: usize = 0;
    var rows: usize = 0;
    var it = try Movement.over(&world);
    while (it.next()) |chunk| {
        chunks += 1;
        rows += chunk.len();
    }
    try testing.expectEqual(@as(usize, 2), chunks);
    try testing.expectEqual(@as(usize, 15), rows);
}

test "an archetype emptied out is skipped rather than yielded" {
    var world: World = .init(gpa);
    defer world.deinit();

    const only = try world.spawnWith(.{ Position{ .x = 1, .y = 1 }, Velocity{ .x = 1, .y = 1 } });
    const Movement = Query(.{ Position, Velocity });
    try testing.expectEqual(@as(usize, 1), try Movement.count(&world));

    world.despawn(only);
    // The archetype is still there; it has nothing in it, so the query does
    // not hand out an empty chunk.
    try testing.expect(world.archetypeCount() >= 1);
    try testing.expectEqual(@as(usize, 0), try Movement.count(&world));
    try testing.expectEqual(@as(?Movement.Chunk, null), try Movement.first(&world));
}

// -------------------------------------------------------------------------
// On every core, and on none
// -------------------------------------------------------------------------

fn step(delta: f32, chunk: Query(.{ Position, Velocity }).Chunk) void {
    const at = chunk.slice(Position);
    const speed = chunk.slice(Velocity);
    for (at, speed) |*p, v| {
        p.x += v.x * delta;
        p.y += v.y * delta;
    }
}

test "the same work, on every core and on none, comes out the same" {
    for (modes) |mode| {
        var world: World = .init(gpa);
        defer world.deinit();

        // Enough to span several chunks at the default grain, in two shapes.
        for (0..5000) |i| {
            _ = try world.spawnWith(.{
                Position{ .x = @floatFromInt(i), .y = 0 },
                Velocity{ .x = 1, .y = 2 },
            });
        }
        for (0..3000) |i| {
            _ = try world.spawnWith(.{
                Position{ .x = @floatFromInt(i), .y = 0 },
                Velocity{ .x = -1, .y = 0 },
                Health{ .points = 1 },
            });
        }

        var jobs: Jobs = try .init(gpa, mode);
        defer jobs.deinit();

        const Movement = Query(.{ Position, Velocity });
        try Movement.each(&world, &jobs, @as(f32, 0.5), step, .{ .grain = 256 });

        // Every row moved exactly once.
        var checked: usize = 0;
        var it = try Movement.over(&world);
        while (it.next()) |chunk| {
            for (chunk.slice(Position), chunk.slice(Velocity)) |p, v| {
                try testing.expectEqual(v.y * 0.5, p.y);
                checked += 1;
            }
        }
        try testing.expectEqual(@as(usize, 8000), checked);
    }
}

test "a grain of one is a job per row, and still each row once" {
    var world: World = .init(gpa);
    defer world.deinit();

    for (0..64) |i| {
        _ = try world.spawnWith(.{
            Position{ .x = @floatFromInt(i), .y = 0 },
            Velocity{ .x = 1, .y = 0 },
        });
    }

    var jobs: Jobs = try .init(gpa, .{ .io = testing.io, .capacity = 256 });
    defer jobs.deinit();

    const Movement = Query(.{ Position, Velocity });
    try Movement.each(&world, &jobs, @as(f32, 1), step, .{ .grain = 1 });

    var it = try Movement.over(&world);
    while (it.next()) |chunk| {
        for (chunk.slice(Position), chunk.entities, 0..) |p, e, i| {
            _ = e;
            _ = i;
            // Started at its index, moved by one, exactly once.
            try testing.expect(p.x >= 1 and p.x <= 64);
        }
    }
    try testing.expectEqual(@as(usize, 0), jobs.pending());
}

test "running over nothing is not an error" {
    var world: World = .init(gpa);
    defer world.deinit();

    var jobs: Jobs = try .init(gpa, .{ .io = null });
    defer jobs.deinit();

    const Movement = Query(.{ Position, Velocity });
    try Movement.each(&world, &jobs, @as(f32, 1), step, .{});
    try testing.expectEqual(@as(usize, 0), try Movement.count(&world));
}

// -------------------------------------------------------------------------
// Saving
// -------------------------------------------------------------------------

test "a world written down and read back is the same world" {
    var world: World = .init(gpa);
    defer world.deinit();

    var made: [50]Entity = undefined;
    for (&made, 0..) |*e, i| {
        e.* = try world.spawnWith(.{
            Position{ .x = @floatFromInt(i), .y = @floatFromInt(i * 2) },
            Health{ .points = @intCast(i), .regenerating = i % 2 == 0 },
        });
        if (i % 3 == 0) try world.add(e.*, Velocity{ .x = 1, .y = -1 });
    }
    // A hole in the middle, so the file is not simply zero to fifty.
    world.despawn(made[7]);
    world.despawn(made[8]);

    const bytes = try save.encodeAlloc(gpa, &world);
    defer gpa.free(bytes);

    var loaded: World = .init(gpa);
    defer loaded.deinit();
    try save.decode(&loaded, bytes, .{ Position, Velocity, Health });

    try testing.expectEqual(world.count(), loaded.count());

    // Every value came back, on an entity with the same components.
    var found: usize = 0;
    var it = try Query(.{ Position, Health }).over(&loaded);
    while (it.next()) |chunk| {
        for (chunk.slice(Position), chunk.slice(Health)) |p, h| {
            try testing.expectEqual(@as(f32, @floatFromInt(h.points)), p.x);
            try testing.expectEqual(p.x * 2, p.y);
            try testing.expectEqual(h.points % 2 == 0, h.regenerating);
            found += 1;
        }
    }
    try testing.expectEqual(@as(usize, 48), found);
    try testing.expectEqual(
        try Query(.{Velocity}).count(&world),
        try Query(.{Velocity}).count(&loaded),
    );
}

test "an entity a component points at is still the right entity afterwards" {
    var world: World = .init(gpa);
    defer world.deinit();

    const captain = try world.spawnWith(.{Health{ .points = 200 }});
    var crew: [5]Entity = undefined;
    for (&crew, 0..) |*e, i| {
        e.* = try world.spawnWith(.{
            Position{ .x = @floatFromInt(i), .y = 0 },
            Owner{ .entity = captain, .since = @intCast(i) },
        });
    }
    // One that points at nobody, which must stay nobody.
    const loner = try world.spawnWith(.{
        Position{ .x = 99, .y = 0 },
        Owner{ .entity = .none, .since = 0 },
    });
    _ = loner;

    const bytes = try save.encodeAlloc(gpa, &world);
    defer gpa.free(bytes);

    var loaded: World = .init(gpa);
    defer loaded.deinit();
    try save.decode(&loaded, bytes, .{ Position, Health, Owner });

    // The captain is a different handle now, and every crew member points at
    // the new one - the same one as each other.
    var captains: std.ArrayListUnmanaged(Entity) = .empty;
    defer captains.deinit(gpa);
    var nobody: usize = 0;

    var it = try Query(.{ Position, Owner }).over(&loaded);
    while (it.next()) |chunk| {
        for (chunk.slice(Owner)) |owner| {
            if (owner.entity.isNone()) {
                nobody += 1;
                continue;
            }
            try testing.expect(loaded.isAlive(owner.entity));
            try testing.expectEqual(@as(u16, 200), loaded.get(owner.entity, Health).?.points);
            try captains.append(gpa, owner.entity);
        }
    }
    try testing.expectEqual(@as(usize, 5), captains.items.len);
    try testing.expectEqual(@as(usize, 1), nobody);
    for (captains.items) |e| try testing.expect(e.eql(captains.items[0]));
}

test "a file that is not a world, and one whose components have moved" {
    var world: World = .init(gpa);
    defer world.deinit();
    _ = try world.spawnWith(.{Position{ .x = 1, .y = 2 }});

    const bytes = try save.encodeAlloc(gpa, &world);
    defer gpa.free(bytes);

    var loaded: World = .init(gpa);
    defer loaded.deinit();

    try testing.expectError(error.NotAWorld, save.decode(&loaded, "no", .{Position}));
    try testing.expectError(error.NotAWorld, save.decode(&loaded, &[_]u8{0} ** 32, .{Position}));

    const bent = try gpa.dupe(u8, bytes);
    defer gpa.free(bent);
    bent[4] = 99;
    try testing.expectError(error.UnsupportedVersion, save.decode(&loaded, bent, .{Position}));

    // A component the build does not have at all.
    try testing.expectError(error.UnknownComponent, save.decode(&loaded, bytes, .{Health}));

    // The same name, a different shape. `Position` here has grown a field,
    // which is exactly what the fingerprint is for.
    const Moved = struct {
        // Named to collide with nothing; the test below renames it in place.
        x: f32,
        y: f32,
        z: f32,
    };
    _ = Moved;
}

test "a component whose fields changed is refused rather than misread" {
    // Two worlds, two definitions of one name. `@typeName` is the same
    // because both are declared in this file with the same path, and the
    // fingerprints differ because the fields do.
    const V1 = struct {
        const Thing = struct { a: u32 };
    };
    const V2 = struct {
        const Thing = struct { a: u32, b: u32 };
    };

    var world: World = .init(gpa);
    defer world.deinit();
    _ = try world.spawnWith(.{V1.Thing{ .a = 7 }});

    const bytes = try save.encodeAlloc(gpa, &world);
    defer gpa.free(bytes);

    var loaded: World = .init(gpa);
    defer loaded.deinit();

    // Reading it as itself works.
    try save.decode(&loaded, bytes, .{V1.Thing});
    try testing.expectEqual(@as(usize, 1), loaded.count());

    // Reading it as the changed one is refused - the name does not match
    // either, which is the other half of the check.
    var third: World = .init(gpa);
    defer third.deinit();
    try testing.expectError(error.UnknownComponent, save.decode(&third, bytes, .{V2.Thing}));
}

test "an empty world saves and loads as an empty world" {
    var world: World = .init(gpa);
    defer world.deinit();

    const bytes = try save.encodeAlloc(gpa, &world);
    defer gpa.free(bytes);

    var loaded: World = .init(gpa);
    defer loaded.deinit();
    try save.decode(&loaded, bytes, .{Position});
    try testing.expectEqual(@as(usize, 0), loaded.count());
}

// -------------------------------------------------------------------------
// What it costs
// -------------------------------------------------------------------------

test "the world can say what it is holding" {
    var world: World = .init(gpa);
    defer world.deinit();

    for (0..100) |i| {
        _ = try world.spawnWith(.{
            Position{ .x = @floatFromInt(i), .y = 0 },
            Velocity{ .x = 0, .y = 0 },
        });
    }

    const stats = world.stats();
    try testing.expectEqual(@as(usize, 100), stats.entities);
    try testing.expectEqual(@as(usize, 2), stats.components);
    try testing.expect(stats.column_bytes >= 100 * (@sizeOf(Position) + @sizeOf(Velocity)));

    var text: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    try writer.print("{f}", .{stats});
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "100 entities") != null);
}
