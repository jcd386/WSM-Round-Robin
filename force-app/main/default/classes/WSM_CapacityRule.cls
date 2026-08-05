/**
 * Only binds when the group's Capacity Mode is Period Cap. Effective cap = member's
 * own Cap Override, else the group's Default Member Cap, else uncapped. An override of
 * exactly 0 blocks the member outright regardless of how few assignments they have.
 */
public inherited sharing class WSM_CapacityRule implements WSM_EligibilityRule {

    public String evaluate(WSM_MemberState member, WSM_GroupState grp, Date today) {
        if (grp.record.WSM_Capacity_Mode__c != 'Period Cap') {
            return null;
        }
        Integer cap = effectiveCap(member, grp);
        if (cap == null) {
            return null;
        }
        Integer count = member.periodCount == null ? 0 : member.periodCount;
        if (count >= cap) {
            return 'At capacity (' + count + '/' + cap + ')';
        }
        return null;
    }

    private Integer effectiveCap(WSM_MemberState member, WSM_GroupState grp) {
        if (member.record.WSM_Cap_Override__c != null) {
            return member.record.WSM_Cap_Override__c.intValue();
        }
        if (grp.record.WSM_Default_Member_Cap__c != null) {
            return grp.record.WSM_Default_Member_Cap__c.intValue();
        }
        return null;
    }
}
