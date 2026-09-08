# Fluxion ECS

The world, and everything in it. For Zig 0.16, on every core the machine has
or on none at all, which is the browser.

| Module | What it is |
| --- | --- |
| `World` | Entities, the components on them, and what it costs. |
| `Query` | Everything with a set of components, in slices. |
| `save` | A world written down and read back. |
| `component` | What a component is allowed to be. |
| `Archetype` | Every entity of one shape, as a table. |
| `Column` | One component's values for one archetype. |

```zig
const ecs = @import("fluxion_ecs");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

var world: ecs.World = .init(gpa);
defer world.deinit();

_ = try world.spawnWith(.{ Position{ .x = 0, .y = 0 }, Velocity{ .x = 1, .y = 0 } });

const Movement = ecs.Query(.{ Position, Velocity });

fn move(delta: f32, chunk: Movement.Chunk) void {
    const at = chunk.slice(Position);
    const speed = chunk.slice(Velocity);
    for (at, speed) |*p, v| {
        p.x += v.x * delta;
        p.y += v.y * delta;
    }
}

try Movement.each(&world, &jobs, delta, move, .{});
```

**Entities are grouped by what they are made of.** Everything with exactly the
same set of components lives in one table, in rows that line up, so a query
hands out plain Zig slices and the loop over them is an ordinary loop the
compiler can vectorise and the processor can prefetch. There is no branch
inside it asking whether this one has a velocity: the query answered that when
it chose which tables to visit.

**Adding a component moves the entity.** Its row is copied into the table with
the larger set and taken out of the one it was in - a handful of `memcpy`s, and
the price of the layout above. An entity whose shape never changes never pays
it, and `spawnWith` puts one straight into its final table rather than moving
it once per component.

**An entity is eight bytes with a generation in them.** A handle to something
that died reads as dead for ever, however many times its slot is reused. It is
a [Fluxion Id](https://github.com/kisstp2006/fluxion-id) handle: a value to
copy, compare, put in a hash map, or store in a component.

## A component is plain data

No pointers, no slices, nothing that owns anything - checked at compile time,
with a message naming the type. That is not a restriction waiting to be lifted.
It is what lets a row be moved with `memcpy`, a removal be a swap with the last
row, a column be handed to a job as a slice, and a world be written to a file
that opens on a different machine. Every one of those stops being true the
moment a component holds a pointer.

The rule is [Fluxion Data](https://github.com/kisstp2006/fluxion-data)'s:
`schema.check` refuses what no format can carry, and `schema.allocates` is
exactly the question "does reading one of these need an allocator", which for a
component must be no. Text in a component is an index into a table of text.

## On every core, and on none

```zig
var jobs: ecs.Jobs = try .init(gpa, .{ .io = io });   // or .{ .io = null }
defer jobs.deinit();

try Movement.each(&world, &jobs, delta, move, .{ .grain = 1024 });
```

`each` cuts the matching rows into chunks and hands each to a
[Fluxion Jobs](https://github.com/kisstp2006/fluxion-jobs) scheduler. Chunks do
not overlap - no row is in two of them - so no two jobs ever touch the same
memory and nothing locks. With no workers the same call runs the chunks on the
calling thread, which is what a browser build does and is the only difference
there.

A hundred thousand entities in three shapes, sixty steps, on an eight-core
machine:

| | wall time |
| --- | --- |
| 7 workers | 15 ms |
| 0 workers | 45 ms |

**What `each` must not do is change the world.** Spawning, despawning, adding
and removing all move rows, and a chunk holds slices of rows. Collect what to
change and do it after the loop.

## In a browser

```bash
zig build web          # zig-out/web/index.html and the .wasm beside it
```

Ten thousand things moving on a canvas, with the world saved and loaded from
inside the page. No threads: `Jobs` sees the target has none and has zero
workers, and the animation frame runs the chunks itself. Nothing in the library
is compiled out and nothing is stubbed.

**It runs anywhere because it does nothing.** No files, no clock, no threads of
its own, no operating system at all - an allocator and arithmetic. Saving hands
you bytes and lets you decide where they go, which is why this works the same
in a browser as on a server.

## Writing a world down

```zig
const bytes = try ecs.save.encodeAlloc(gpa, &world);
defer gpa.free(bytes);

var loaded: ecs.World = .init(gpa);
defer loaded.deinit();
try ecs.save.decode(&loaded, bytes, .{ Position, Velocity, Health });
```

```
FXWD              four bytes, so a file that is not one is noticed at once
version           one byte: the container's own
flags, padding    three bytes of zero
components        how many, then each one's name and schema fingerprint
shapes            every archetype: its components, and which entities are in
                  which row
values            every archetype's columns, in the same order
```

**The shapes come before the values, and that is what makes loading one pass.**
Every entity in the file exists before the first component is read, so a
component holding a reference to an entity in the last archetype can be
rewritten while reading the first.

**Components go through Fluxion Data, not through `memcpy`.** Writing the
columns as they sit in memory would be quicker and would make a save only the
machine that wrote it can read: padding, endianness and field order are the
compiler's business. Each value goes through its own type's encoder instead.

**A component is found by name and checked by fingerprint.** The name is
`@typeName(T)`, stable across runs; the fingerprint says whether the fields are
still what they were. A file whose `Position` has grown a `z` is refused rather
than read as something it is not.

**Entities come back as different entities, and references still work.** A
handle cannot be reproduced exactly - its generation counts how many things
have lived in a slot, and a fresh world has had none - so loading mints new
ones and rewrites every `Entity` stored inside a component to match. That walk
is generated per component type at compile time, so an entity three structs
deep inside a component is rewritten too, and a component with none costs
nothing at all.

## What is not here yet

- **A system scheduler.** Systems are functions you call; there is no graph
  that reads their component access and runs the ones that do not conflict at
  the same time. The parallelism here is inside one query, which is where most
  of it is.
- **Relations and hierarchies.** A parent is an `Entity` in a component, which
  works and is not the same as a library that knows about trees.
- **Zero-sized tags.** A component must have at least one field; a marker with
  no data would need a column that stores nothing.
- **Change detection.** Nothing records which rows were written this frame.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-ecs
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_ecs = .{ .path = "../fluxion-ecs" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_ecs", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_ecs", fluxion.module("fluxion_ecs"));
```

```zig
const ecs = @import("fluxion_ecs");
```

Four dependencies come with it, fetched the same way and needing nothing from
you: [Fluxion Id](https://github.com/kisstp2006/fluxion-id) for the handle an
entity is, [Fluxion Mem](https://github.com/kisstp2006/fluxion-mem) for the
alignment a type-erased column is laid out with and the byte counts it reports,
[Fluxion Data](https://github.com/kisstp2006/fluxion-data) for what a component
may be and how one is written down, and
[Fluxion Jobs](https://github.com/kisstp2006/fluxion-jobs) for running a query
on more than one core.

## Where it sits

The fourth tier of the Fluxion licence ladder: `BSD-3-Clause`, the engine's own
rung. Its dependencies are one tier-one library and three tier-two ones, which
would put it on the third; its subject matter puts it here, because a world is
not a subsystem an engine uses - it is what the engine is. That tier asks two
things of what you ship: the copyright notice reproduced in the documentation,
and that the project's name is not used to endorse what you made with it.

## The tests

Thirty-nine, and the ones that matter are about what happens between the
pieces, because that is where an archetype design goes wrong: a row removed
from the middle of a table while sixty-three others watch, an entity changing
shape while its neighbours' rows shuffle under it, a handle to something dead
that must not answer for whatever took its slot.

Every parallel test runs twice, once with as many workers as the machine gives
and once with none, and checks the two agree. The saving tests write a world
with entities pointing at each other, load it into a fresh world, and check
that every reference found the same new entity.

## Build

```bash
zig build test        # run the test suite, and build the wasm
zig build example     # 100k entities on every core and on none, then saved
zig build web         # the browser example into zig-out/web
zig build docs        # generate API documentation into zig-out/docs
```

## Licence

`BSD-3-Clause`. See [LICENSE](LICENSE).
