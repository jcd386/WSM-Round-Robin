/** Orders by WSM_Last_Assigned__c ASC NULLS FIRST, then WSM_Sort_Order__c NULLS LAST, then Id. */
public inherited sharing class WSM_StrictRotationStrategy implements WSM_ISelectionStrategy {

    public List<WSM_MemberState> sortMembers(List<WSM_MemberState> members) {
        List<WSM_MemberState> ordered = members.clone();
        ordered.sort(new RankComparator());
        return ordered;
    }

    public WSM_MemberState selectNext(List<WSM_MemberState> eligibleMembers) {
        List<WSM_MemberState> ordered = sortMembers(eligibleMembers);
        return ordered.isEmpty() ? null : ordered[0];
    }

    private class RankComparator implements Comparator<WSM_MemberState> {
        public Integer compare(WSM_MemberState a, WSM_MemberState b) {
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
