/**
 * Blocks a member who has reached the Cap on any of the group's Cap-role Capacity
 * Queries. Like every other rule this is a pure comparison: the counts were loaded onto
 * the member state by the engine before the pipeline ran, so this behaves identically
 * inside a locked assign() and inside preview().
 *
 * Definitions that failed to compile are skipped here rather than blocking anyone. A
 * broken capacity query must not be able to stop routing for the whole group; the engine
 * surfaces the reason as a warning on the assignment log instead.
 */
public inherited sharing class WSM_CapacityQueryRule implements WSM_EligibilityRule {

    public String evaluate(WSM_MemberState member, WSM_GroupState grp, Date today) {
        if (grp == null || grp.capacityQueries == null || grp.capacityQueries.isEmpty()) {
            return null;
        }
        for (WSM_CapacityQueryDef def : grp.capacityQueries) {
            if (def.isValid != true || !def.isCap) {
                continue;
            }
            Integer cap = def.cap;
            if (cap == null) {
                continue;
            }
            Integer count = member.capacityCount(def.configId);
            if (count >= cap) {
                // Wording starts with "At capacity" so WSM_AssignmentLogger groups it
                // under the existing "at cap" category in the skip summary.
                return 'At capacity on ' + def.label + ' (' + count + '/' + cap + ')';
            }
        }
        return null;
    }
}
