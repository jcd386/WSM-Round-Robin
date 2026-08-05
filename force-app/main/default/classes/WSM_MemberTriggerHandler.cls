public inherited sharing class WSM_MemberTriggerHandler {

    private static final Integer MIN_WEIGHT = 1;
    private static final Integer MAX_WEIGHT = 100;
    private static final Integer DEFAULT_WEIGHT = 1;

    public void run(List<WSM_Round_Robin_Member__c> members) {
        for (WSM_Round_Robin_Member__c member : members) {
            setUniqueKey(member);
            defaultWeight(member);
            validateWeight(member);
        }
    }

    private void setUniqueKey(WSM_Round_Robin_Member__c member) {
        if (member.WSM_Group__c == null || member.WSM_User__c == null) {
            member.WSM_Unique_Key__c = null;
        } else {
            member.WSM_Unique_Key__c = member.WSM_Group__c + '|' + member.WSM_User__c;
        }
    }

    private void defaultWeight(WSM_Round_Robin_Member__c member) {
        if (member.WSM_Weight__c == null) {
            member.WSM_Weight__c = DEFAULT_WEIGHT;
        }
    }

    private void validateWeight(WSM_Round_Robin_Member__c member) {
        if (member.WSM_Weight__c < MIN_WEIGHT || member.WSM_Weight__c > MAX_WEIGHT) {
            member.WSM_Weight__c.addError('Weight must be between 1 and 100.');
        }
    }
}
