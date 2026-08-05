public inherited sharing class WSM_ActiveRule implements WSM_EligibilityRule {

    public String evaluate(WSM_MemberState member, WSM_GroupState grp, Date today) {
        return member.record.WSM_Active__c == true ? null : 'Inactive';
    }
}
