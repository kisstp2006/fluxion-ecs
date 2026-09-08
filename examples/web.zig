// SPDX-License-Identifier: BSD-3-Clause

//! A world running in a browser. Built by `zig build web` into `zig-out/web/`,
//! and driven by `index.html` next to it.
//!
//! The same world, the same query and the same `each` as the native demo. What
//! is different is that `wasm32-freestanding` has no threads, so the scheduler
//! has no workers and every chunk runs on the thread that asked for it - which
//! is the page's animation frame. Nothing in the library is compiled out and
//! nothing is stubbed: it is the same code, doing the work in one place.
//!
//! The page also saves and loads the world, which is worth seeing in a browser
//! because it is the same bytes a native build writes.

const std = @import("std");
const ecs = @import("fluxion_ecs");

const gpa = std.heap.wasm_allocator;

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };
const Colour = struct { r: u8, g: u8, b: u8 };

const Movement = ecs.Query(.{ Position, Velocity });

var world: ?ecs.World = null;
var jobs: ?ecs.Jobs = null;
/// Where the page reads the points from: x, y, r, g, b per entity, as floats
/// so the page has one array to walk.
var points: []f32 = &.{};
var width: f32 = 0;
var height: f32 = 0;
var saved: []u8 = &.{};

/// Fill a world with `n` things and start a scheduler for it.
export fn start(n: u32, w: f32, h: f32) u32 {
    stop();
    width = w;
    height = h;

    var made: ecs.World = .init(gpa);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();

    for (0..n) |i| {
        const at: Position = .{ .x = random.float(f32) * w, .y = random.float(f32) * h };
        const speed: Velocity = .{
            .x = (random.float(f32) * 2 - 1) * 60,
            .y = (random.float(f32) * 2 - 1) * 60,
        };
        const colour: Colour = .{
            .r = @intCast(60 + (i * 7) % 195),
            .g = @intCast(60 + (i * 13) % 195),
            .b = 255 - @as(u8, @intCast((i * 3) % 180)),
        };
        // Two shapes, so the query has more than one archetype to walk - the
        // same as the native demo, and the same as a real world.
        if (i % 4 == 0) {
            _ = made.spawnWith(.{ at, speed }) catch break;
        } else {
            _ = made.spawnWith(.{ at, speed, colour }) catch break;
        }
    }

    world = made;
    jobs = ecs.Jobs.init(gpa, .{ .capacity = 4096 }) catch {
        stop();
        return 0;
    };
    points = gpa.alloc(f32, n * 5) catch {
        stop();
        return 0;
    };
    return @intCast(world.?.count());
}

/// Move everything by `delta` seconds and fill the point array.
export fn frame(delta: f32) u32 {
    const w = &(world orelse return 0);
    const j = &(jobs orelse return 0);

    Movement.each(w, j, Step{ .delta = delta, .width = width, .height = height }, step, .{}) catch return 0;

    var at: usize = 0;
    var it = Drawing.over(w) catch return 0;
    while (it.next()) |chunk| {
        const places = chunk.slice(Position);
        const colours = chunk.slice(Colour);
        for (places, colours) |p, c| {
            if (at + 5 > points.len) break;
            points[at + 0] = p.x;
            points[at + 1] = p.y;
            points[at + 2] = @floatFromInt(c.r);
            points[at + 3] = @floatFromInt(c.g);
            points[at + 4] = @floatFromInt(c.b);
            at += 5;
        }
    }
    return @intCast(at / 5);
}

const Drawing = ecs.Query(.{ Position, Colour });

const Step = struct { delta: f32, width: f32, height: f32 };

/// One system, and the only one. The same function the native demo uses.
fn step(ctx: Step, chunk: Movement.Chunk) void {
    const places = chunk.slice(Position);
    const speeds = chunk.slice(Velocity);
    for (places, speeds) |*p, *v| {
        p.x += v.x * ctx.delta;
        p.y += v.y * ctx.delta;
        // Bounce, so nothing wanders off the canvas.
        if (p.x < 0) {
            p.x = 0;
            v.x = -v.x;
        }
        if (p.x > ctx.width) {
            p.x = ctx.width;
            v.x = -v.x;
        }
        if (p.y < 0) {
            p.y = 0;
            v.y = -v.y;
        }
        if (p.y > ctx.height) {
            p.y = ctx.height;
            v.y = -v.y;
        }
    }
}

/// Where the points are, for the page to draw straight out of memory.
export fn pointsPtr() [*]f32 {
    return points.ptr;
}

/// How many entities are alive.
export fn entityCount() u32 {
    const w = &(world orelse return 0);
    return @intCast(w.count());
}

/// How many worker threads the scheduler has. Zero in a browser, which is
/// the thing this example is about.
export fn workers() u32 {
    const j = &(jobs orelse return 0);
    return @intCast(j.workerCount());
}

/// How many archetypes the world has settled into.
export fn archetypes() u32 {
    const w = &(world orelse return 0);
    return @intCast(w.archetypeCount());
}

/// Bytes the world's columns have asked for.
export fn columnBytes() u32 {
    const w = &(world orelse return 0);
    return @intCast(w.stats().column_bytes);
}

// -------------------------------------------------------------------------
// Saving, in a browser
// -------------------------------------------------------------------------

/// Write the world down. Returns how many bytes, or zero if it could not.
export fn save() u32 {
    const w = &(world orelse return 0);
    if (saved.len != 0) gpa.free(saved);
    saved = ecs.save.encodeAlloc(gpa, w) catch {
        saved = &.{};
        return 0;
    };
    return @intCast(saved.len);
}

/// Throw the world away and read the saved one back. Returns how many
/// entities came back.
export fn load() u32 {
    if (saved.len == 0) return 0;
    var fresh: ecs.World = .init(gpa);
    ecs.save.decode(&fresh, saved, .{ Position, Velocity, Colour }) catch {
        fresh.deinit();
        return 0;
    };
    if (world) |*old| old.deinit();
    world = fresh;
    return @intCast(world.?.count());
}

export fn savedPtr() [*]u8 {
    return saved.ptr;
}

export fn stop() void {
    if (jobs) |*j| j.deinit();
    jobs = null;
    if (world) |*w| w.deinit();
    world = null;
    if (points.len != 0) gpa.free(points);
    points = &.{};
    if (saved.len != 0) gpa.free(saved);
    saved = &.{};
}
