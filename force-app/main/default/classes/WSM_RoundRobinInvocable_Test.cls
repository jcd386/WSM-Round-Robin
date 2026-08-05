/** Coverage for the flow-facing invocable: order preservation, developer-name resolution, and malformed-input handling. */
@isTest
private class WSM_RoundRobinInvocable_Test {

    @isTest
    static void getAssignee_preservesOrderAcrossMixedRequests() {
        WSM_Round_Robin_Group__c groupA = WSM_RoundRobinTestFactory.insertGroup('Invocable Order A', 'Strict Rotation');
        WSM_Round_Robin_Group__c groupB = WSM_RoundRobinTestFactory.insertGroup('Invocable Order B', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMember(groupA.Id, users[0].Id);
        WSM_RoundRobinTestFactory.insertMember(groupB.Id, users[1].Id);

        WSM_RoundRobinInvocable.Request reqB = new WSM_RoundRobinInvocable.Request();
        reqB.groupId = groupB.Id;
        WSM_RoundRobinInvocable.Request reqA = new WSM_RoundRobinInvocable.Request();
        reqA.groupId = groupA.Id;

        List<WSM_RoundRobinInvocable.Result> results = WSM_RoundRobinInvocable.getAssignee(
            new List<WSM_RoundRobinInvocable.Request>{ reqB, reqA }
        );

        System.assertEquals(2, results.size());
        System.assertEquals(groupB.Id, results[0].groupId, 'Result order must mirror request order.');
        System.assertEquals(users[1].Id, results[0].userId);
        System.assertEquals(groupA.Id, results[1].groupId, 'Result order must mirror request order.');
        System.assertEquals(users[0].Id, results[1].userId);
    }

    @isTest
    static void getAssignee_developerNameResolution_zeroAndTwoMatches() {
        WSM_Round_Robin_Group__c groupA = WSM_RoundRobinTestFactory.insertGroup('DevName A', 'Strict Rotation');
        groupA.WSM_Developer_Name__c = 'invocable_dev_a';
        WSM_Round_Robin_Group__c groupB = WSM_RoundRobinTestFactory.insertGroup('DevName B', 'Strict Rotation');
        groupB.WSM_Developer_Name__c = 'invocable_dev_b';
        update new List<WSM_Round_Robin_Group__c>{ groupA, groupB };
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMember(groupA.Id, users[0].Id);
        WSM_RoundRobinTestFactory.insertMember(groupB.Id, users[1].Id);

        WSM_RoundRobinInvocable.Request matchA = new WSM_RoundRobinInvocable.Request();
        matchA.groupDeveloperName = 'invocable_dev_a';
        WSM_RoundRobinInvocable.Request matchB = new WSM_RoundRobinInvocable.Request();
        matchB.groupDeveloperName = 'invocable_dev_b';
        WSM_RoundRobinInvocable.Request noMatch = new WSM_RoundRobinInvocable.Request();
        noMatch.groupDeveloperName = 'no_such_group';

        List<WSM_RoundRobinInvocable.Result> results = WSM_RoundRobinInvocable.getAssignee(
            new List<WSM_RoundRobinInvocable.Request>{ matchA, matchB, noMatch }
        );

        System.assertEquals(3, results.size());
        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, results[0].status, 'The first of two valid developer names should resolve.');
        System.assertEquals(groupA.Id, results[0].groupId);
        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, results[1].status, 'The second of two valid developer names should resolve.');
        System.assertEquals(groupB.Id, results[1].groupId);
        System.assertEquals(WSM_RRResult.STATUS_GROUP_NOT_FOUND, results[2].status,
            'An unresolvable developer name must produce GROUP_NOT_FOUND, not an exception.');
    }

    @isTest
    static void getAssignee_malformedGroupIdIsHandledGracefully() {
        WSM_RoundRobinInvocable.Request req = new WSM_RoundRobinInvocable.Request();
        req.groupId = 'not-a-real-id';

        List<WSM_RoundRobinInvocable.Result> results = WSM_RoundRobinInvocable.getAssignee(new List<WSM_RoundRobinInvocable.Request>{ req });

        System.assertEquals(1, results.size());
        System.assertEquals(WSM_RRResult.STATUS_GROUP_NOT_FOUND, results[0].status,
            'A malformed Id string must resolve to GROUP_NOT_FOUND, never an unhandled exception.');
    }

    @isTest
    static void getAssignee_fieldsMapThroughToResultAndLog() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Mapping Group', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_Round_Robin_Member__c member = WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        WSM_RoundRobinInvocable.Request req = new WSM_RoundRobinInvocable.Request();
        req.groupId = grp.Id;
        req.assignedRecordId = grp.Id; // any valid Id works as a stand-in "routed record"
        req.context = 'Unit Test Flow';

        WSM_RoundRobinInvocable.Result result = WSM_RoundRobinInvocable.getAssignee(new List<WSM_RoundRobinInvocable.Request>{ req })[0];

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status);
        System.assertEquals(true, result.isSuccess);
        System.assertEquals(member.Id, result.memberId);
        System.assertEquals(users[0].Id, result.userId);
        System.assertEquals(grp.Id, result.groupId);
        System.assertNotEquals(null, result.logId);

        WSM_Assignment_Log__c log = [SELECT WSM_Context__c, WSM_Assigned_Record_Id__c FROM WSM_Assignment_Log__c WHERE Id = :result.logId];
        System.assertEquals('Unit Test Flow', log.WSM_Context__c);
        System.assertEquals(String.valueOf(grp.Id), log.WSM_Assigned_Record_Id__c);
    }
}
