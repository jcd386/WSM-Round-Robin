/** Coverage for the public WSM_RoundRobinService facade: delegation, developer-name resolution, and preview. */
@isTest
private class WSM_RoundRobinService_Test {

    @isTest
    static void assignByGroupId_delegatesAndReturnsSingleResult() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Service Group', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        WSM_RRResult result = WSM_RoundRobinService.assign(grp.Id);

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status);
        System.assertEquals(users[0].Id, result.userId);
        System.assertNotEquals(null, result.logId);
    }

    @isTest
    static void assignByDeveloperName_happyPath() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Dev Name Group', 'Strict Rotation');
        grp.WSM_Developer_Name__c = 'dev_name_group';
        update grp;
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        WSM_RRResult result = WSM_RoundRobinService.assignByDeveloperName('Dev_Name_Group');

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status, 'Developer name lookup should be case-insensitive.');
        System.assertEquals(grp.Id, result.groupId);
    }

    @isTest
    static void assignByDeveloperName_noMatchReturnsGroupNotFound() {
        WSM_RRResult result = WSM_RoundRobinService.assignByDeveloperName('does_not_exist');

        System.assertEquals(WSM_RRResult.STATUS_GROUP_NOT_FOUND, result.status);
        System.assertEquals(false, result.isSuccess);
    }

    @isTest
    static void assignList_preservesCountAndOrder() {
        WSM_Round_Robin_Group__c groupA = WSM_RoundRobinTestFactory.insertGroup('Service Order A', 'Strict Rotation');
        WSM_Round_Robin_Group__c groupB = WSM_RoundRobinTestFactory.insertGroup('Service Order B', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMember(groupA.Id, users[0].Id);
        WSM_RoundRobinTestFactory.insertMember(groupB.Id, users[1].Id);

        List<WSM_RRResult> results = WSM_RoundRobinService.assign(new List<WSM_RRRequest>{
            new WSM_RRRequest(groupB.Id), new WSM_RRRequest(groupA.Id)
        });

        System.assertEquals(2, results.size());
        System.assertEquals(groupB.Id, results[0].groupId, 'Result order must mirror request order.');
        System.assertEquals(groupA.Id, results[1].groupId, 'Result order must mirror request order.');
    }

    @isTest
    static void preview_delegatesToEngineWithoutDml() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Preview Facade Group', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_Round_Robin_Member__c member = WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        Integer dmlBefore = Limits.getDmlStatements();
        WSM_RRPreview preview = WSM_RoundRobinService.preview(grp.Id);

        System.assertEquals(dmlBefore, Limits.getDmlStatements(), 'preview() must never issue DML, even through the facade.');
        System.assertEquals(member.Id, preview.wouldAssignMemberId);
        System.assertEquals(1, preview.verdicts.size());
    }

    @isTest
    static void withSharingService_worksForRestrictedUser() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Service Smoke Group', 'Strict Rotation');
        List<User> poolUsers = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, poolUsers[0].Id);
        User restrictedUser = WSM_RoundRobinTestFactory.insertRestrictedUser();

        System.runAs(restrictedUser) {
            WSM_RRResult result = WSM_RoundRobinService.assign(grp.Id);
            System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status,
                'The with-sharing facade must still work end-to-end for a non-admin running user.');
        }
    }
}
