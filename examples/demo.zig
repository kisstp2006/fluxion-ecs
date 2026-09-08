// SPDX-License-Identifier: BSD-3-Clause

//! A tour of Fluxion ECS. Run it with `zig build example`.
//!
//! It fills a world with a hundred thousand things, moves them with every core
//! and then with none, shows the two agree, and then writes the world down and
//! reads it back - including the entities that point at each other.

const std = @import("std");
const Io = std.Io;
const ecs = @import("fluxion_ecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Health = struct { points: u16, regenerating: bool = false };
/// What makes saving interesting: a component that names another entity.
const Escorting = struct { leader: ecs.Entity };

const count = 100_000;
const steps = 60;

const Movement = ecs.Query(.{ Position, Velocity });

/// One chunk of the world, moved by `delta`. This is the whole of a system.
fn move(delta: f32, chunk: Movement.Chunk) void {
    const at = chunk.slice(Position);
    const speed = chunk.slice(Velocity);
    for (at, speed) |*p, v| {
        p.x += v.x * delta;
        p.y += v.y * delta;
        // Bounce off a box, so the numbers stay somewhere a person can read.
        if (p.x < 0 or p.x > 1000) p.x = std.math.clamp(p.x, 0, 1000);
        if (p.y < 0 or p.y > 1000) p.y = std.math.clamp(p.y, 0, 1000);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    // --- a world ---------------------------------------------------------

    var world: ecs.World = .init(gpa);
    defer world.deinit();
    try fill(&world);

    try out.print("--- the world ---\n{f}\n", .{world.stats()});
    try out.print("{d} of them move, {d} of those are also alive\n\n", .{
        try Movement.count(&world),
        try ecs.Query(.{ Position, Velocity, Health }).count(&world),
    });

    // --- the same work, two ways -----------------------------------------

    try out.print("--- {d} steps over {d} entities ---\n", .{ steps, count });
    const threaded = try run(gpa, io, &world, .{ .io = io, .workers = .auto });
    try out.print("{d: >2} workers: {d} ms\n", .{ threaded.workers, threaded.ms });

    // The world has moved, so put it back before running it again.
    world.deinit();
    world = .init(gpa);
    try fill(&world);

    const alone = try run(gpa, io, &world, .{ .io = null });
    try out.print("{d: >2} workers: {d} ms (the browser's way)\n", .{ alone.workers, alone.ms });
    try out.print("same answer: {}\n\n", .{approximately(threaded.checksum, alone.checksum)});

    // --- writing it down --------------------------------------------------

    const bytes = try ecs.save.encodeAlloc(gpa, &world);
    try out.print("--- saved ---\n{d} bytes for {d} entities\n", .{ bytes.len, world.count() });

    var loaded: ecs.World = .init(gpa);
    defer loaded.deinit();
    try ecs.save.decode(&loaded, bytes, .{ Position, Velocity, Health, Escorting });

    try out.print("loaded: {f}\n", .{loaded.stats()});

    // Every escort still follows the same leader, though every handle in the
    // world is a different number than it was.
    var escorts: usize = 0;
    var leaders_alive: usize = 0;
    var it = try ecs.Query(.{Escorting}).over(&loaded);
    while (it.next()) |chunk| {
        for (chunk.slice(Escorting)) |escorting| {
            escorts += 1;
            if (loaded.isAlive(escorting.leader)) leaders_alive += 1;
        }
    }
    try out.print("{d} escorts, {d} of their leaders still there\n", .{ escorts, leaders_alive });

    try out.flush();
}

/// A hundred thousand things in three shapes, plus a few that follow.
fn fill(world: *ecs.World) !void {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();

    var leaders: [16]ecs.Entity = undefined;
    for (&leaders) |*leader| {
        leader.* = try world.spawnWith(.{
            Position{ .x = random.float(f32) * 1000, .y = random.float(f32) * 1000 },
            Velocity{ .x = random.float(f32) * 2 - 1, .y = random.float(f32) * 2 - 1 },
            Health{ .points = 1000 },
        });
    }

    for (0..count) |i| {
        const at: Position = .{ .x = random.float(f32) * 1000, .y = random.float(f32) * 1000 };
        const speed: Velocity = .{ .x = random.float(f32) * 2 - 1, .y = random.float(f32) * 2 - 1 };

        // Three shapes, so the query has more than one archetype to walk.
        switch (i % 3) {
            0 => _ = try world.spawnWith(.{ at, speed }),
            1 => _ = try world.spawnWith(.{ at, speed, Health{ .points = 100 } }),
            else => _ = try world.spawnWith(.{
                at,
                speed,
                Escorting{ .leader = leaders[i % leaders.len] },
            }),
        }
    }
}

const Run = struct { workers: usize, ms: u64, checksum: f64 };

/// Sixty steps, and what the world adds up to afterwards.
fn run(gpa: std.mem.Allocator, io: Io, world: *ecs.World, options: ecs.Jobs.Options) !Run {
    var jobs: ecs.Jobs = try .init(gpa, options);
    defer jobs.deinit();

    const started = Io.Timestamp.now(io, .awake);
    for (0..steps) |_| {
        try Movement.each(world, &jobs, @as(f32, 1.0 / 60.0), move, .{});
    }
    const finished = Io.Timestamp.now(io, .awake);

    var total: f64 = 0;
    var it = try Movement.over(world);
    while (it.next()) |chunk| {
        for (chunk.slice(Position)) |p| total += p.x + p.y;
    }

    return .{
        .workers = jobs.workerCount(),
        .ms = @intCast(@divTrunc(finished.nanoseconds - started.nanoseconds, std.time.ns_per_ms)),
        .checksum = total,
    };
}

/// Floating point addition is not associative, so two runs that did the same
/// work in a different order agree to within what that costs.
fn approximately(a: f64, b: f64) bool {
    const scale = @max(@abs(a), @abs(b));
    return @abs(a - b) <= scale * 1e-9;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "a small world moves the same way with workers and without" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var threaded: ecs.World = .init(gpa);
    defer threaded.deinit();
    var alone: ecs.World = .init(gpa);
    defer alone.deinit();

    for (0..1000) |i| {
        const at: Position = .{ .x = @floatFromInt(i), .y = 0 };
        const speed: Velocity = .{ .x = 1, .y = 2 };
        _ = try threaded.spawnWith(.{ at, speed });
        _ = try alone.spawnWith(.{ at, speed });
    }

    var with: ecs.Jobs = try .init(gpa, .{ .io = io });
    defer with.deinit();
    var without: ecs.Jobs = try .init(gpa, .{ .io = null });
    defer without.deinit();

    for (0..10) |_| {
        try Movement.each(&threaded, &with, @as(f32, 0.1), move, .{ .grain = 64 });
        try Movement.each(&alone, &without, @as(f32, 0.1), move, .{ .grain = 64 });
    }

    var a = try Movement.over(&threaded);
    var b = try Movement.over(&alone);
    while (a.next()) |left| {
        const right = b.next().?;
        try std.testing.expectEqualSlices(Position, left.slice(Position), right.slice(Position));
    }
    try std.testing.expect(b.next() == null);
}
