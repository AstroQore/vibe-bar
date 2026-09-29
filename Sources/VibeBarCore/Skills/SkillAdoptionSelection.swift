import Foundation

/// Which harnesses an unmanaged app-folder skill is linked back into when the
/// import sheet adopts it.
///
/// Adoption copies the folder into `~/.agents/skills` and replaces the
/// original with a link only for the harnesses it is given. A harness the
/// folder was found in but left out of that set keeps its own, user-authored
/// copy — and keeps loading it while the registry says it is unselected. So
/// every seeded or copied selection includes the row's own `foundIn`; the
/// defaults and "apply to every row" can only add harnesses, never drop the
/// one the skill already lives in. The user can still untick one by hand.
public enum SkillAdoptionSelection {
    /// What a row starts with when it is checked: the user's default
    /// harnesses plus every harness the scan found the folder in.
    public static func seed(
        foundIn: [SkillAppTarget],
        defaults: [SkillAppTarget]
    ) -> Set<SkillAppTarget> {
        Set(foundIn).union(defaults)
    }

    /// Another row's selection copied onto this one, keeping this row's own
    /// source harnesses.
    public static func copy(
        _ selection: Set<SkillAppTarget>,
        onto foundIn: [SkillAppTarget]
    ) -> Set<SkillAppTarget> {
        selection.union(foundIn)
    }
}
