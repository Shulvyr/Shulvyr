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

The compiler bootstrap tool requires Python 3.12 or newer on x86_64 Linux or
Windows. It verifies the official archive against the hashes in
[tools/zig-downloads.json](tools/zig-downloads.json).

```sh
python tools/bootstrap_zig.py
```

Add the printed compiler's directory to your PATH. See
[development notes](docs/development.md) for module contracts and checks.

Logos and visual assets are maintained in [Shulvyr/branding](https://github.com/Shulvyr/branding).

Not an official Minecraft product. Not approved by or associated with Mojang or Microsoft.
