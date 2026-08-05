/**
 * Picks the lowest period-assignment count. Calibration=Median seeds any member with
 * zero assignments this period (which by construction from the period-filtered
 * aggregate means no assignment since period start) at floor(median of the eligible
 * pool's raw counts), so new or returning members don't get flooded to "catch up" —
 * Calibration=None leaves them at their true zero.
 */
public inherited sharing class WSM_LeastAssignedStrategy implements WSM_ISelectionStrategy {

    private static final String CALIBRATION_MEDIAN = 'Median';

    private String calibration;

    public WSM_LeastAssignedStrategy(String calibration) {
        this.calibration = calibration;
    }

    public List<WSM_MemberState> sortMembers(List<WSM_MemberState> members) {
        Map<Id, Integer> effective = effectiveCounts(members);
        List<WSM_MemberState> ordered = members.clone();
        ordered.sort(new RankComparator(effective));
        return ordered;
    }

    public WSM_MemberState selectNext(List<WSM_MemberState> eligibleMembers) {
        List<WSM_MemberState> ordered = sortMembers(eligibleMembers);
        return ordered.isEmpty() ? null : ordered[0];
    }

    private Map<Id, Integer> effectiveCounts(List<WSM_MemberState> members) {
        Boolean calibrate = calibration == CALIBRATION_MEDIAN;
        Integer medianFloor = calibrate ? medianOf(members) : 0;
        Map<Id, Integer> result = new Map<Id, Integer>();
        for (WSM_MemberState m : members) {
            Integer raw = m.periodCount == null ? 0 : m.periodCount;
            result.put(m.record.Id, (calibrate && raw == 0) ? medianFloor : raw);
        }
        return result;
    }

    private Integer medianOf(List<WSM_MemberState> members) {
        if (members.isEmpty()) {
            return 0;
        }
        List<Integer> counts = new List<Integer>();
        for (WSM_MemberState m : members) {
            counts.add(m.periodCount == null ? 0 : m.periodCount);
        }
        counts.sort();
        Integer n = counts.size();
        if (Math.mod(n, 2) == 1) {
            return counts[n / 2];
        }
        Decimal avg = (counts[n / 2 - 1] + counts[n / 2]) / 2.0;
        return avg.intValue();
    }

    private class RankComparator implements Comparator<WSM_MemberState> {
        private Map<Id, Integer> effective;

        RankComparator(Map<Id, Integer> effective) {
            this.effective = effective;
        }

        public Integer compare(WSM_MemberState a, WSM_MemberState b) {
            Integer countA = effective.get(a.record.Id);
            Integer countB = effective.get(b.record.Id);
            if (countA != countB) {
                return countA < countB ? -1 : 1;
            }
            Integer byLastAssigned = compareDatetimeNullsFirst(a.lastAssigned, b.lastAssigned);
            if (byLastAssigned != 0) {
                return byLastAssigned;
            }
            Integer bySortOrder = compareDecimalNullsLast(a.record.WSM_Sort_Order__c, b.record.WSM_Sort_Order__c);
            if (bySortOrder != 0) {
                return bySortOrder;
            }
            return compareIds(a.record.Id, b.record.Id);
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

    private static Integer compareIds(Id a, Id b) {
        return String.valueOf(a).compareTo(String.valueOf(b));
    }
}
