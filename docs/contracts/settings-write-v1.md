# Writing `settings.json` — v1

`~/.vibebar/settings.json` has two writers: this app and Vibe Bar
Desktop, in any combination of versions. This is the rule both must
follow. Unlike the other contracts here there is no generated fixture —
what has to match is a procedure, not a table — so it is written out.

## The failure it prevents

Both clients used to hold settings as a decoded struct and save by
rewriting the whole file from it. That deletes every key the writer did
not know about:

- a setting the *other client* has and this one does not;
- a setting a *newer version* added, when an older version saves;
- a setting the other client changed a moment ago, overwritten from a
  copy read at launch.

Nothing reports it. The user sees a setting revert some time later, with
no way to connect it to the save that did it.

## The rule

A writer keeps three things, not one:

| | |
| --- | --- |
| `baseline` | the file's raw JSON object as this process last saw it — at load, and after each of its own writes |
| `mine` | the settings this process holds, encoded to a JSON object |
| `theirs` | the file's raw JSON object, **re-read immediately before writing** |

A write is then:

1. `changed` = the top-level keys where `mine` differs from **the value
   this process last wrote**, including keys it wrote and no longer has
   — but a key is only *absent* if this build could have written it
   (below).

   Not against `baseline`. A settings file from an older version is
   missing keys this build knows, and decoding materialises defaults for
   them; measured against the file every one of those looks like a
   choice this process made, and the next save writes them over whatever
   the other client had put there. What this process changed is what
   changed *here*.

   The same reasoning covers the file this build cannot decode at all: it
   holds defaults in memory so there is something to show, takes them as
   its starting position, and does not save them. Writing defaults over a
   newer client's file is the downgrade version of the loss this whole
   rule exists to prevent, and it would happen before the user had
   touched anything.
2. Start from `theirs`. Apply `changed`, setting or removing each key.
3. Write that, atomically.
4. `baseline` = what was written.

Everything not in `changed` keeps the value the file already had,
whatever it means to this build.

### Vocabulary

Step 1's exception matters more than it looks. An encoded settings
object never mentions a key the build has never heard of, so *every*
unknown key looks like a deletion, and the merge would delete exactly
what it exists to protect. A vanished key is a removal only when it is
one this build could have written: the union of the keys in a
default-valued settings object and the keys in `mine`. Anything else is
someone else's, and is preserved.

### Granularity

Top-level keys. Two clients editing different fields *inside* one
top-level object — say two entries of `miniWindow` — still resolve to
one of them winning that object. Settings are edited by hand and rarely;
a deep merge has no defensible answer for arrays, and buys precision
nobody has needed against surprises everyone would meet.

### Format

Pretty-printed, keys sorted, written to a temporary file and renamed.
A merged write must be byte-indistinguishable from a plain one.

## Reading the file back

A writer must also notice the *other* writer, or its `baseline` is
frozen at launch and its own settings are stale for as long as it runs.
Watch the file; on change, re-read and take on what changed.

Two details, both of which were got wrong first:

- **Atomic writes replace the inode.** A watch on the file descriptor
  keeps watching a file nobody will write to again. Treat delete and
  rename as the signal to re-open the path, not merely as events.
- **A file that does not exist yet still has a first write.** Opening a
  path that was missing a moment ago *is* the change; no event will
  arrive for the write that created it.

Where both sides changed the same setting, the file wins — it is the
shared state, and keeping a value the file no longer holds is the stale
reading this watching exists to end.

Three more, each of which turns the merge against itself if missed:

- **Do not advance `baseline` until the merged object decodes.** A newer
  writer can put a value in the file this build cannot read — an enum
  case added since. Recording it as seen lets the next save diff our old
  values against it and write them over the newer writer's, which is
  precisely the loss the merge exists to prevent. A file that cannot be
  read has not been seen.
- **A setting adopted from the other writer is theirs, not ours.** Move
  it in the record of this process's own previous values, and drop it
  from the set of settings this process changed. Otherwise the next save
  claims it, and the next time they touch it the user is told their own
  choice was replaced — about a value they never picked.
- **A coalesced save in flight holds a snapshot from before the
  adoption.** Left to run it writes those values back and undoes what
  was just adopted. Replace it rather than cancel it: the snapshot is
  stale, the unsaved edits in it are not.
- **A write can beat the watcher to an external change.** It re-reads,
  keeps the other writer's keys, and records the result as the file it
  has seen — after which the watcher compares the file with a baseline
  that already contains their change and finds nothing. The write has to
  report what it folded in, or this client shows settings the file
  stopped holding some time ago.
- **A notice stands until the user dismisses it.** A later external
  change that costs nothing is not news that the first one cost nothing,
  and a second loss is a second thing to say rather than a replacement
  for the first.

## Telling the user

The one cost of the file winning is that a choice the user made here can
be replaced. Report exactly that case, and no other:

> the settings **this process changed since it launched**, which the
> other writer has since changed to a different value.

Measured against this process's own previous value, not against the
file. Measuring against the file counts every default the file did not
happen to carry as a user's choice, so the first save claims authorship
of the whole document and the next external edit reports most of it as
lost. An external change to a setting nobody here touched is adopted
silently — nothing was lost, and a notice would be noise.

## The lock

Re-reading and renaming are two steps, so two writers can interleave
between them and the second one's merge is based on a file that no
longer exists. Both steps go under one lock.

```
~/.vibebar/run/settings.lock      mode 0600, in a run/ directory of 0700
```

`flock(2)`, `LOCK_EX`, blocking, held from the re-read to the rename and
released by closing the descriptor. Not a lock file holding a pid: the
kernel drops a `flock` when the descriptor closes, process death
included, so there is no stale lock to break and no liveness check to
get wrong. It is advisory, which binds the clients that ask for it —
both of them.

Rust takes the same lock through `flock(2)` on the same path; the
primitive is the same from either language, and the interop is worth a
test rather than an assumption.

**Failing to take the lock is not failing to write.** A read-only or
unusual filesystem falls back to the unlocked behaviour, which is what
both clients did until now. The narrow race is worth closing; it is not
worth a new way to lose settings.

Reads do not take it. A write is a rename, so a reader either sees the
whole old file or the whole new one.

## Size

8 MiB, refused rather than truncated. A settings file is a few tens of
kilobytes; anything near the cap is a corrupt or hostile file, and a
reader that refuses it falls back to its defaults rather than parsing it.

## What this supersedes

Vibe Bar Desktop's `docs/contracts/settings-document-v1.md` records an
earlier design for the same problem, kept as a design record after its
implementation was removed. Two of its decisions are deliberately not
carried over, and one is:

- **No `schemaVersion` / `revision` envelope.** That design had both
  clients adopt one together; neither did, and the file in the field has
  neither key. A writer that added them alone would be adding keys the
  reference implementation never emits, to a file whose whole point is
  that unknown keys are somebody else's.
- **A contested key goes to the last writer, not the first.** That
  design left a key alone when the file had moved and reported a
  conflict, so a user's most recent click could silently fail to take
  effect. Here the write applies it, a later external change replaces
  it, and either way the person who is told is the one whose choice was
  replaced.
- **The 8 MiB cap and the writer whitelist are kept**, both from that
  design.

## Why there is no revision counter

An earlier sketch of this had every writer carry a revision, so a client
could tell that the file had moved under it. With the lock, a write
cannot be based on a stale read; with the baseline, a client already
knows *which* settings changed, which is strictly more than a counter
would tell it, and is what the user is shown. A revision would be a
number both clients maintain and neither consults.
