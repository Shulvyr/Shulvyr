# Shulvyr

An independent Minecraft: Bedrock server project written in Zig.

Development has started with the foundation runtime. It runs a finite tick loop
and provides binary and NBT codecs, bounded queues, generational handles and timers.
Bedrock networking and gameplay are not implemented yet.

## Build

Use Zig 0.17.0, as pinned in [.zigversion](.zigversion).

```sh
zig build
zig build test
zig build run -- --ticks 20
zig build run -- --help
```

The default run completes 20 logical ticks at a target rate of 20 Hz. The current
runtime opens no network sockets or worlds.

Download the matching official archive recorded in
[tools/zig-downloads.json](tools/zig-downloads.json), verify its SHA-256 and add
the extracted compiler's directory to your PATH. CI uses runner OS tools for
this initial compiler installation. Maintenance commands use Zig:

```sh
zig build check-tools --summary all
zig build check-fixtures --summary all
```

Reference fixture generators live in
[Shulvyr/reference-tools](https://github.com/Shulvyr/reference-tools).
The optional [native transport experiment](docs/native-transport.md) uses a Zig
build driver in this repository. See [development notes](docs/development.md)
for module contracts and checks.

Logos and visual assets are maintained in [Shulvyr/branding](https://github.com/Shulvyr/branding).

Not an official Minecraft product. Not approved by or associated with Mojang or Microsoft.
