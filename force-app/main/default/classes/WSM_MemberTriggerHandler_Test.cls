@IsTest
private class WSM_MemberTriggerHandler_Test {

    private static WSM_Round_Robin_Group__c seedGroup() {
        WSM_Round_Robin_Group__c g = new WSM_Round_Robin_Group__c(
            Name = 'Test Group ' + System.now().getTime(),
            WSM_Developer_Name__c = 'test_group_' + System.now().getTime()
        );
        insert g;
        return g;
    }

    @IsTest
    static void testDuplicateSeatBlockedByUniqueKeyOnInsert() {
        WSM_Round_Robin_Group__c g = seedGroup();
        Id userId = UserInfo.getUserId();

        WSM_Round_Robin_Member__c m1 = new WSM_Round_Robin_Member__c(WSM_Group__c = g.Id, WSM_User__c = userId);
        insert m1;

        WSM_Round_Robin_Member__c m2 = new WSM_Round_Robin_Member__c(WSM_Group__c = g.Id, WSM_User__c = userId);
        Boolean threw = false;

        Test.startTest();
        try {
            insert m2;
        } catch (DmlException e) {
            threw = true;
            System.assert(
                e.getMessage().toLowerCase().contains('duplicate'),
                'Expected a duplicate value error, got: ' + e.getMessage()
            );
        }
        Test.stopTest();

        System.assert(threw, 'A second member with the same group + user should be blocked by the unique key');
    }

    @IsTest
    static void testUniqueKeySetOnInsert() {
        WSM_Round_Robin_Group__c g = seedGroup();
        Id userId = UserInfo.getUserId();

        WSM_Round_Robin_Member__c m = new WSM_Round_Robin_Member__c(WSM_Group__c = g.Id, WSM_User__c = userId);
        insert m;

        m = [SELECT WSM_Unique_Key__c FROM WSM_Round_Robin_Member__c WHERE Id = :m.Id];
        System.assertEquals(g.Id + '|' + userId, m.WSM_Unique_Key__c, 'Unique key should be groupId|userId');
    }

    @IsTest
    static void testBlankUserProducesNullKeyAndAllowsMultipleSeats() {
        WSM_Round_Robin_Group__c g = seedGroup();

        WSM_Round_Robin_Member__c m1 = new WSM_Round_Robin_Member__c(WSM_Group__c = g.Id);
        insert m1;

        WSM_Round_Robin_Member__c m2 = new WSM_Round_Robin_Member__c(WSM_Group__c = g.Id);
        insert m2;

        List<WSM_Round_Robin_Member__c> members = [
            SELECT WSM_Unique_Key__c
            FROM WSM_Round_Robin_Member__c
            WHERE Id IN :new List<Id>{ m1.Id, m2.Id }
        ];
        System.assertEquals(2, members.size(), 'Both blank-user seats should have inserted successfully');
        for (WSM_Round_Robin_Member__c m : members) {
            System.assertEquals(null, m.WSM_Unique_Key__c, 'Blank-user seats should not receive a unique key');
        }
    }

    @IsTest
    static void testWeightDefaultsToOneWhenNull() {
        WSM_Round_Robin_Group__c g = seedGroup();

        WSM_Round_Robin_Member__c m = new WSM_Round_Robin_Member__c(WSM_Group__c = g.Id);
        insert m;

        m = [SELECT WSM_Weight__c FROM WSM_Round_Robin_Member__c WHERE Id = :m.Id];
        System.assertEquals(1, m.WSM_Weight__c, 'Weight should default to 1 when left blank on insert');
    }

    @IsTest
    static void testWeightValidationRejectsTooLow() {
        WSM_Round_Robin_Group__c g = seedGroup();
        WSM_Round_Robin_Member__c m = new WSM_Round_Robin_Member__c(WSM_Group__c = g.Id, WSM_Weight__c = 0);

        Boolean threw = false;
        try {
            insert m;
        } catch (DmlException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('Weight must be between 1 and 100.'),
                'Expected the weight range error, got: ' + e.getMessage()
            );
        }
        System.assert(threw, 'A weight of 0 should be rejected');
    }

    @IsTest
    static void testWeightValidationRejectsTooHigh() {
        WSM_Round_Robin_Group__c g = seedGroup();
        WSM_Round_Robin_Member__c m = new WSM_Round_Robin_Member__c(WSM_Group__c = g.Id, WSM_Weight__c = 101);

        Boolean threw = false;
        try {
            insert m;
        } catch (DmlException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('Weight must be between 1 and 100.'),
                'Expected the weight range error, got: ' + e.getMessage()
            );
        }
        System.assert(threw, 'A weight of 101 should be rejected');
    }

    @IsTest
    static void testWeightValidationRunsOnUpdate() {
        WSM_Round_Robin_Group__c g = seedGroup();
        WSM_Round_Robin_Member__c m = new WSM_Round_Robin_Member__c(WSM_Group__c = g.Id, WSM_Weight__c = 50);
        insert m;

        m.WSM_Weight__c = 200;
        Boolean threw = false;
        try {
            update m;
        } catch (DmlException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('Weight must be between 1 and 100.'),
                'Expected the weight range error, got: ' + e.getMessage()
            );
        }
        System.assert(threw, 'A weight of 200 on update should be rejected');
    }

    @IsTest
    static void testUniqueKeyUpdatesWhenUserChanges() {
        WSM_Round_Robin_Group__c g = seedGroup();
        Id userId = UserInfo.getUserId();

        WSM_Round_Robin_Member__c m = new WSM_Round_Robin_Member__c(WSM_Group__c = g.Id);
        insert m;

        m.WSM_User__c = userId;
        update m;

        m = [SELECT WSM_Unique_Key__c FROM WSM_Round_Robin_Member__c WHERE Id = :m.Id];
        System.assertEquals(g.Id + '|' + userId, m.WSM_Unique_Key__c, 'Unique key should recompute when the user is set on update');
    }
}
