import Foundation

/// `settings.json` as it exists on disk, rather than as this build understands
/// it.
///
/// Two things make the difference matter. A second client — Vibe Bar Desktop —
/// reads and will write the same file, and an older build of this app knows
/// fewer keys than a newer one. In both cases a whole-file rewrite from a
/// decoded `AppSettings` silently deletes every key the writer did not happen
/// to know about, and the loss is invisible until someone goes looking for a
/// setting that has quietly reverted.
///
/// So writes go through here: decode for the app, keep the raw object, and put
/// back only the keys this process actually changed. Everything else on disk
/// survives untouched, including keys this build has never heard of.
enum SettingsDocument {
    /// A JSON object, as `JSONSerialization` gives it.
    typealias Object = [String: Any]

    /// Read the file as an object. Nil when it is absent or not an object —
    /// a caller should then fall back to its defaults rather than assume an
    /// empty document, which would look like "every setting was cleared".
    static func read(from url: URL) -> Object? {
        guard let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
        return object(from: data)
    }

    /// A settings file is a few tens of kilobytes. Anything approaching this
    /// is a corrupt or hostile file, not settings, and parsing it into memory
    /// is work with nothing at the end of it.
    static let maximumBytes = 8 * 1024 * 1024

    static func object(from data: Data) -> Object? {
        (try? JSONSerialization.jsonObject(with: data)) as? Object
    }

    static func object<T: Encodable>(encoding value: T) -> Object? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return object(from: data)
    }

    /// The bytes to write, in the same shape `VibeBarLocalStore.writeJSON`
    /// produces, so a merged write is indistinguishable from a plain one.
    static func data(from object: Object) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Which top-level keys differ between two objects, in either direction.
    ///
    /// `owned` is the vocabulary the comparison is allowed to speak. Without
    /// it every key this build cannot encode looks like a deletion — an
    /// encoded `AppSettings` never mentions a key it has never heard of — and
    /// the merge would delete exactly the keys it exists to protect. Nil means
    /// "both objects speak the same vocabulary", which is true when comparing
    /// two states of the file itself.
    ///
    /// Key granularity is a deliberate limit: two clients editing *different*
    /// fields inside the same top-level object still resolve to one of them
    /// winning that whole object. Settings are edited by hand and rarely, so
    /// the alternative — a deep merge, which has no obvious right answer for
    /// arrays — buys precision nobody needs at a cost in surprises.
    static func changedKeys(
        from baseline: Object,
        to current: Object,
        owned: Set<String>? = nil
    ) -> Set<String> {
        var changed = Set<String>()
        for (key, value) in current where !equal(value, baseline[key]) {
            changed.insert(key)
        }
        // A key that vanished is a removal only if the writer could have
        // written it in the first place.
        for key in baseline.keys where current[key] == nil {
            if owned?.contains(key) ?? true { changed.insert(key) }
        }
        return changed
    }

    /// Apply this process's own edits onto whatever is on disk now.
    ///
    /// A three-way merge: `baseline` is what we last saw, `mine` is what we
    /// want, `theirs` is what the file says now. Only the keys we changed move;
    /// every other key keeps the value the file already had, whether or not
    /// this build knows what it means.
    static func merge(
        baseline: Object,
        mine: Object,
        theirs: Object,
        owned: Set<String>? = nil
    ) -> Object {
        var result = theirs
        for key in changedKeys(from: baseline, to: mine, owned: owned) {
            if let value = mine[key] {
                result[key] = value
            } else {
                result.removeValue(forKey: key)
            }
        }
        return result
    }

    /// The keys both sides changed since the baseline, and disagree about.
    ///
    /// These are the only edits a merge can cost someone: everywhere else both
    /// clients get what they asked for. Surfacing them is the difference
    /// between "your change was replaced" and a setting that silently reverts.
    static func conflictingKeys(
        baseline: Object,
        mine: Object,
        theirs: Object,
        owned: Set<String>? = nil
    ) -> Set<String> {
        changedKeys(from: baseline, to: mine, owned: owned)
            .intersection(changedKeys(from: baseline, to: theirs))
            .filter { !equal(mine[$0], theirs[$0]) }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }

    /// JSON value equality. `NSObject.isEqual` handles the nested dictionaries
    /// and arrays `JSONSerialization` produces; the nil cases are spelled out
    /// because a key that is absent and a key that is present are different
    /// facts, and `NSNull` is a third one.
    static func equal(_ left: Any?, _ right: Any?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        default: return (left as AnyObject).isEqual(right as AnyObject)
        }
    }
}
