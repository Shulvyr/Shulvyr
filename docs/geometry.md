# Geometry contracts

The selected behavior reference is the latest `stable` branch of
[PocketMine Math](https://github.com/pmmp/Math/tree/stable), resolved to
[d74ed5a](https://github.com/pmmp/Math/tree/d74ed5a788092df8e8ec15609b36535ed96587f9)
for the committed oracle fixtures. Axolotl-PM and Altay use this library.
The [Dragonfly traversal](https://github.com/df-mc/dragonfly/blob/1793369709ceed934675d69e86ff6c828e4216c8/server/block/cube/trace/trace.go)
was also inspected for its boundary and tie conventions. Differential tests here
execute PocketMine Math through a development-only PHP generator.

## Values and precision

`Vec3` stores three f64 values. Arithmetic uses strict floating-point operations
and returns values without allocation. Basic add/subtract/scale/dot/cross
operations retain IEEE arithmetic. Validate results at external boundaries.
Normalization checks finite inputs and rejects squared-length overflow. A zero
squared length, including underflow to zero, normalizes to the zero vector.

`floorBlock` floors each axis before converting to i32. NaN, infinity and values
whose floor is outside i32 are rejected. `coordinates.splitPosition` uses floor
division on all three axes with 16-block subchunks. Local coordinates are 0-15.
`joinPosition` checks overflow independently on every axis. These are coordinate
representations, without a protocol-specific world height or border policy.

Oracle numeric comparisons allow `1e-12 * max(1, abs(expected))` absolute error.
Booleans, block positions, hit faces and voxel order must agree exactly. This
does not establish accuracy for arbitrary magnitudes or future physics code.

## Boxes and segment queries

`Aabb` accepts finite, ordered bounds, including zero-width boxes. Query methods
validate bounds even when a caller constructed the struct directly. `contains`
excludes the faces. `intersects` requires both opposing face separations to be
strictly greater than its nonnegative finite epsilon on every axis. This retains
the oracle's degenerate-box behavior and is not a positive-volume test. The
default epsilon constant is 1e-5.

`clipOffset` treats the receiver as a stationary obstacle and clips another box's
signed displacement on one axis. Contact on either other axis prevents clipping.
It does not perform a complete movement transaction or world collision query.

`castSegment` returns the nearest face hit in the closed segment, including an
exit when starting inside. Parallel axes with squared displacement below 1e-7
are ignored. Equal-distance face hits prefer west, east, down, up, north, south.
The nearest-hit search retains the oracle's 64-bit PHP_INT_MAX squared-distance
ceiling. Very distant intersections can therefore return no hit. Nonfinite inputs
and derived fractions, hit positions or squared hit distances fail explicitly.

## Voxel traversal

`VoxelRay.init(start, end, max_steps)` validates both endpoint floors against i32
and rejects a zero normalized direction. The allocation-free iterator yields
the starting floor cell first. Every later cell differs by one axis step.
Boundary ties cross Z, then Y, then X. Endpoints on grid boundaries retain the
oracle's crossing behavior and can include the cell beyond that boundary.

The mandatory budget counts returned cells and is capped at 1000000. Exhaustion
returns `StepLimit`. Stepping outside i32 returns `CoordinateOverflow`. Both
errors are sticky and preserve the last cell. Natural completion returns null
on every subsequent call. Consumers must distinguish errors from completion.
The iterator belongs to one execution context and should only be changed by its
constructor and `next` method.

## Oracle corpus

The committed corpus contains 80 cases. The manifest records source repository,
branch and revision, generator SHA-256 and output size/SHA-256. Input definitions
are in the generator. Regeneration requires Git, a clean checkout at the recorded
revision and 64-bit PHP 8.4 or newer. No Composer installation is needed.

```sh
php tools/generate_math_fixtures.php work/math-reference/Math
zig build check-fixtures --summary all
zig build test --summary all
```

Before refreshing, resolve the source's current default branch, review its
changes and update the recorded revision. Inspect regenerated outputs before
accepting them. The corpus covers these primitives, not a complete world raycast,
collision system or gameplay implementation.
