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

1. `changed` = the top-level keys where `mine` differs from `baseline`,
   including keys present in `baseline` and absent from `mine` — but a
   key is only *absent* if this build could have written it (below).
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

## Why there is no revision counter

An earlier sketch of this had every writer carry a revision, so a client
could tell that the file had moved under it. With the lock, a write
cannot be based on a stale read; with the baseline, a client already
knows *which* settings changed, which is strictly more than a counter
would tell it, and is what the user is shown. A revision would be a
number both clients maintain and neither consults.
