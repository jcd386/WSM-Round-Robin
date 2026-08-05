trigger WSM_RoundRobinMemberTrigger on WSM_Round_Robin_Member__c (before insert, before update) {
    new WSM_MemberTriggerHandler().run(Trigger.new);
}
