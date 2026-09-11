/**
 * Picks whoever carries the least existing work in the org, where "work" is the sum of
 * the group's Load Metric capacity query counts, each multiplied by its own Load Weight.
 * The result is divided by the member's Weight so the same 1-100 weight that speeds a
 * member up under Weighted also gives them a bigger share here: weight 3 against weight
 * 1 settles at roughly three assignments to one.
 *
 * Unlike Least Assigned, which counts only what this tool handed out this period, the
 * load here is measured off the customer's own records. That matters because it is the
 * number that actually moves when work arrives from anywhere, including outside the
 * round robin, so the pool self-levels instead of drifting.
 *
 * externalLoad is precomputed onto each member by the engine, which keeps this strategy a
 * pure ranking function with no access to group config.
 */
public inherited sharing class WSM_ExternalLoadStrategy implements WSM_ISelectionStrategy {

    private static final Decimal MIN_WEIGHT = 1;
    private static final Decimal MAX_WEIGHT = 100;

    public List<WSM_MemberState> sortMembers(List<WSM_MemberState> members) {
        List<WSM_MemberState> ordered = members.clone();
        ordered.sort(new RankComparator());
        return ordered;
    }

    public WSM_MemberState selectNext(List<WSM_MemberState> eligibleMembers) {
        List<WSM_MemberState> ordered = sortMembers(eligibleMembers);
        return ordered.isEmpty() ? null : ordered[0];
    }

    /**
     * Load per unit of weight. A heavier weight divides the load down, so that member
     * stays "cheapest" for longer and wins more often.
     */
    @TestVisible
    private static Decimal effectiveLoad(WSM_MemberState member) {
        Decimal load = member.externalLoad == null ? 0 : member.externalLoad;
        return load / clampWeight(member.record.WSM_Weight__c);
    }

    private static Decimal clampWeight(Decimal weight) {
        if (weight == null) {
            return MIN_WEIGHT;
        }
        if (weight < MIN_WEIGHT) {
            return MIN_WEIGHT;
        }
        return weight > MAX_WEIGHT ? MAX_WEIGHT : weight;
    }

    private class RankComparator implements Comparator<WSM_MemberState> {
        public Integer compare(WSM_MemberState a, WSM_MemberState b) {
            Decimal loadA = effectiveLoad(a);
            Decimal loadB = effectiveLoad(b);
            if (loadA != loadB) {
                return loadA < loadB ? -1 : 1;
            }
            // Same load: fall through to the rotation tie-breaks so repeated calls inside
            // one transaction still alternate instead of stacking on the same member.
            Integer byLastAssigned = compareDatetimeNullsFirst(a.lastAssigned, b.lastAssigned);
            if (byLastAssigned != 0) {
                return byLastAssigned;
            }
            Integer bySortOrder = compareDecimalNullsLast(a.record.WSM_Sort_Order__c, b.record.WSM_Sort_Order__c);
            if (bySortOrder != 0) {
                return bySortOrder;
            }
            return String.valueOf(a.record.Id).compareTo(String.valueOf(b.record.Id));
        }
    }

    private static Integer compareDatetimeNullsFirst(Datetime a, Datetime b) {
        if (a == null && b == null) {
            return 0;
        }
        if (a == null) {
            return -1;
        }
        if (b == null) {
            return 1;
        }
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    private static Integer compareDecimalNullsLast(Decimal a, Decimal b) {
        if (a == null && b == null) {
            return 0;
        }
        if (a == null) {
            return 1;
        }
        if (b == null) {
            return -1;
        }
        return a < b ? -1 : (a > b ? 1 : 0);
    }
}
