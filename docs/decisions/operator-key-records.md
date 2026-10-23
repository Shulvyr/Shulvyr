# Operator key records

Status: implemented

Use one private append-only file for the operator key history. Each generation
has a checksummed key record followed by a separately flushed commit checksum.
Keep the storage implementation in Zig with standard filesystem I/O and the
host's native access-control APIs.

Rotation must preserve the previous committed identity when preparation is
interrupted. Keeping the filename stable avoids replacing directory entries on
every rotation and provides one complete prefix to validate after restart.
Creation and backup still require directory and parent synchronization. A full
new commit observed after a reported I/O failure must be verified and flushed
before use, since an error response cannot prove that no write reached disk.

Recovery is an explicit operation tied to the last complete public fingerprint.
It can discard a partial tail but cannot reinterpret a full corrupt frame or
remove a later valid commit. Initialization never repairs or replaces an
existing store. This makes identity changes visible to the operator and leaves
damaged evidence available for backup restoration.

The trade-off is retention of old private records. The format has a hard record
limit and no automatic compaction. It relies on owner-only OS access rather
than introducing another persistent wrapping secret or an account-bound
encryption format. A future encrypted format or compactor needs its own version,
explicit migration and failure/recovery evidence. The current checksums provide
corruption detection and do not defend against a writable-store owner.

See [operator key storage](../operator-keys.md) for the wire layout, command
contract, ownership and verification scope.
