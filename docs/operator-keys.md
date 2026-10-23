# Operator key storage

Shulvyr stores an operator P-384 key independently of transport certificates.
The key survives restarts and can issue new identity assertions. Loading a key
does not authenticate a player, validate a service token or bind an SDP
fingerprint to an actual certificate. Those negotiation gates remain separate.

## Commands

```sh
zig build run -- identity init
zig build run -- identity show
zig build run -- identity inspect
zig build run -- identity rotate --expected FINGERPRINT
zig build run -- identity backup --destination .shulvyr-backup
zig build run -- identity recover --expected FINGERPRINT
```

Replace `FINGERPRINT` with the 64-digit SHA-256 fingerprint printed by `show`.
The default directory is `.shulvyr`. Every command accepts `--directory PATH`.
Its parent must already exist. Initialization creates a private child and
refuses any nonempty destination. `show` never creates a missing store.
Use a parent controlled by the server account and keep state outside source
and package directories. The default directory and `operator.keys` files are
ignored by Git. Commands print public metadata and errors, never key bytes.

`rotate` requires the currently observed fingerprint. A stale retry cannot
rotate an identity that already changed. `backup` copies the complete committed
history into a new private destination. It refuses an existing destination file.
To restore, stop the owner and select the backup directory with `--directory`.
Check its fingerprint before accepting it as the server identity.

## Access and ownership

`OperatorKeyStore` owns an exclusive file lock and directory/file handles.
Its parent is a borrowed, already-open directory capability that must outlive
the store. The process-relative `Dir.cwd()` sentinel is refused. Open `.` first
when it is the intended parent. Serialize methods and destruction in a
management context. They perform synchronous filesystem I/O and do not belong
in world ticks or native callbacks. Do not duplicate the store or loaded key.

Linux requires the effective account's ownership, directory mode `0700` and
file mode `0600`. Windows creates a protected DACL with one full-access ACE for
the process account and verifies ownership and the actual DACL through the
opened handle. It uses the system Advapi32 APIs, including
[GetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo).
Existing insecure objects are refused rather than having their rights changed.
Links, reparse points, nonregular files and key files with multiple hard links
are refused. Parent capabilities must remain stable during use.

The file is unencrypted and includes retired private keys. Protect backups with
the same care as the active store. Checksums detect corruption, they do not
authenticate a file against an account that can rewrite it. This is an OS
account boundary, not isolation from privileged software or native plugins.
Compaction and physical erasure are not implemented. The record limit fails
explicitly rather than discarding history or changing the identity.

## Format and commit boundary

The [storage decision](decisions/operator-key-records.md) records the choice
of an append-only file and its recovery and key-retention trade-offs.

`operator.keys` has a 16-byte header followed by 160-byte frames. Integers use
little endian. The header is eight bytes `SVYRKEY\0`, a `u32` format version of
one and a `u32` frame length of 160. Other headers are refused.

| Frame offset | Bytes | Field |
| --- | --- | --- |
| 0 | 8 | Generation, starting at one and increasing by one |
| 8 | 48 | Canonical nonzero big-endian P-384 secret scalar |
| 56 | 32 | SHA-256 of canonical uncompressed public-key SPKI |
| 88 | 8 | Reserved zeros |
| 96 | 32 | SHA-256 of the file header followed by frame bytes 0 through 95 |
| 128 | 32 | Commit checksum |

The commit checksum is SHA-256 of `Shulvyr operator key commit v1\0` followed
by the first 128 frame bytes. A write first appends those 128 bytes and flushes
the file, then appends the commit checksum and flushes again. A successful
rotation follows the second flush. Initialization and backup additionally
flush the key directory and its parent so their namespace entries have a
filesystem commit boundary. Windows reopens directory capabilities with write
access for this operation. Linux reopens them for reading because Zig's default
lookup-only directories use `O_PATH`, which does not support
[`fsync`](https://man7.org/linux/man-pages/man2/open.2.html).
Unsupported synchronization is an error.

The default and hard limit is 4,096 records, at most 655,376 bytes. A caller may
choose a smaller limit. Loading validates the entire committed prefix with
fixed scratch buffers, validates the selected public fingerprint and flushes
the observed commit before returning an owned key. Secret scratch buffers are
cleared on success and failure. The caller clears its returned key with `deinit`.

## Failure and recovery

A short trailing frame is uncommitted data. `show`, rotation and backup refuse
it. `inspect` reports the last complete identity and trailing byte count without
returning a signing key. `recover` requires that identity's fingerprint and
truncates only the partial tail, then flushes the file. A complete corrupt
frame is preserved and refused. It is never treated as an incomplete append.

After a write or flush failure, `KeyStoreCommitUncertain` poisons the current
handle. Close it and reopen. A complete new frame may be present even though
the earlier caller received an error. Loading verifies and flushes that actual
commit before use. Recovery cannot roll a valid later commit back to an older
fingerprint. Do not continue admission with a cached old key after uncertainty.

An interrupted first initialization with no complete record has no committed
identity to recover. It is preserved. Restore a protected backup or explicitly
choose a new directory and identity. No command silently generates a replacement.

Tests cover separate-process restart, rotation, backup restoration, permissions,
exclusive ownership, hard links, malformed records, partial writes and failed
prepare/final flushes. These exercise filesystem API boundaries. Hardware
power-loss testing and real-client identity negotiation have not been performed.
