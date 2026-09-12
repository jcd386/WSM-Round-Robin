@IsTest
private class WSM_RR_AdminController_Test {

    // ------------------------------------------------------------------
    // Shared test data
    // ------------------------------------------------------------------

    @TestSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>();
        for (Integer i = 1; i <= 8; i++) {
            users.add(new User(
                FirstName = 'RRTest',
                LastName = 'User' + i,
                Email = 'rrtestuser' + i + '@wsmrrtest.invalid',
                Username = 'rrtestuser' + i + '@wsmrrtest.invalid.' + UserInfo.getOrganizationId(),
                Alias = 'rrt' + i,
                TimeZoneSidKey = 'America/Chicago',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                ProfileId = p.Id,
                IsActive = true
            ));
        }
        insert users;
    }

    private static List<User> testUsers() {
        return [SELECT Id, Name FROM User WHERE FirstName = 'RRTest' ORDER BY LastName ASC LIMIT 8];
    }

    private static WSM_Round_Robin_Group__c seedGroup(String algorithm) {
        WSM_Round_Robin_Group__c g = new WSM_Round_Robin_Group__c(
            Name = 'RR Test Group ' + System.currentTimeMillis() + Math.round(Math.random() * 1000),
            WSM_Developer_Name__c = 'rr_test_group_' + System.currentTimeMillis() + Math.round(Math.random() * 1000),
            WSM_Algorithm__c = algorithm,
            WSM_Active__c = true
        );
        insert g;
        return g;
    }

    private static WSM_Round_Robin_Member__c seedMember(Id groupId, Id userId, Integer sortOrder) {
        WSM_Round_Robin_Member__c m = new WSM_Round_Robin_Member__c(
            WSM_Group__c = groupId,
            WSM_User__c = userId,
            WSM_Active__c = true,
            WSM_Weight__c = 1,
            WSM_Sort_Order__c = sortOrder
        );
        insert m;
        return m;
    }

    private static WSM_Assignment_Log__c seedLog(Id groupId, Id memberId, Id assignedUserId, String status) {
        WSM_Assignment_Log__c log = new WSM_Assignment_Log__c(
            WSM_Group__c = groupId,
            WSM_Member__c = memberId,
            WSM_Assigned_User__c = assignedUserId,
            WSM_Status__c = status,
            WSM_Algorithm__c = 'Strict Rotation',
            WSM_Context__c = 'Unit Test',
            WSM_Detail__c = 'test detail',
            WSM_Assigned_Record_Id__c = String.valueOf(groupId)
        );
        insert log;
        return log;
    }

    // ------------------------------------------------------------------
    // getGroups
    // ------------------------------------------------------------------

    @IsTest
    static void testGetGroupsReturnsSummaryWithMemberAndAssignmentCounts() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        WSM_Round_Robin_Member__c m1 = seedMember(g.Id, users[0].Id, 10);
        seedMember(g.Id, users[1].Id, 20);

        seedLog(g.Id, m1.Id, users[0].Id, 'Assigned');
        seedLog(g.Id, m1.Id, users[0].Id, 'Assigned');
        seedLog(g.Id, m1.Id, users[1].Id, 'Fallback');

        Test.startTest();
        List<WSM_RR_AdminController.GroupSummary> summaries = WSM_RR_AdminController.getGroups();
        Test.stopTest();

        WSM_RR_AdminController.GroupSummary match;
        for (WSM_RR_AdminController.GroupSummary s : summaries) {
            if (s.groupId == g.Id) {
                match = s;
            }
        }
        System.assertNotEquals(null, match, 'The seeded group should appear in getGroups()');
        System.assertEquals(g.Name, match.name, 'Name should match');
        System.assertEquals(g.WSM_Developer_Name__c, match.developerName, 'Developer name should match');
        System.assertEquals('Strict Rotation', match.algorithm, 'Algorithm should match');
        System.assertEquals(true, match.active, 'Group should be active');
        System.assertEquals(2, match.memberCount, 'Both members should be counted');
        System.assertEquals(2, match.assignments30d, 'Only Assigned-status logs should count toward assignments30d');
    }

    // ------------------------------------------------------------------
    // getGroupDetail
    // ------------------------------------------------------------------

    @IsTest
    static void testGetGroupDetailReturnsGroupInfoMembersAndLogs() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Weighted');
        g.WSM_Capacity_Mode__c = 'Period Cap';
        g.WSM_Default_Member_Cap__c = 5;
        g.WSM_Period__c = 'Daily';
        g.WSM_Fallback_User__c = users[2].Id;
        update g;

        WSM_Round_Robin_Member__c m1 = seedMember(g.Id, users[0].Id, 10);
        WSM_Round_Robin_Member__c m2 = seedMember(g.Id, users[1].Id, 20);
        m2.WSM_Cap_Override__c = 2;
        update m2;

        seedLog(g.Id, m1.Id, users[0].Id, 'Assigned');

        Test.startTest();
        WSM_RR_AdminController.GroupDetail detail = WSM_RR_AdminController.getGroupDetail(g.Id);
        Test.stopTest();

        System.assertEquals(g.Id, detail.grp.id, 'Group id should match');
        System.assertEquals(g.Name, detail.grp.name, 'Group name should match');
        System.assertEquals('Weighted', detail.grp.algorithm, 'Algorithm should match');
        System.assertEquals('Period Cap', detail.grp.capacityMode, 'Capacity mode should match');
        System.assertEquals(5, detail.grp.defaultMemberCap, 'Default cap should match');
        System.assertEquals(users[2].Id, detail.grp.fallbackUserId, 'Fallback user id should match');
        System.assertEquals(users[2].Name, detail.grp.fallbackUserName, 'Fallback user name should resolve');
        System.assertEquals('Daily', detail.periodLabel, 'Period label should reflect group Period');
        System.assertEquals(true, detail.hasAnyLog, 'A log exists so hasAnyLog should be true');
        System.assertEquals(1, detail.recentLogs.size(), 'One log should be returned');

        System.assertEquals(2, detail.members.size(), 'Both members should be returned');
        Map<Id, WSM_RR_AdminController.MemberRow> rowsByMemberId = new Map<Id, WSM_RR_AdminController.MemberRow>();
        for (WSM_RR_AdminController.MemberRow row : detail.members) {
            rowsByMemberId.put(row.memberId, row);
        }

        WSM_RR_AdminController.MemberRow row1 = rowsByMemberId.get(m1.Id);
        System.assertEquals(5, row1.effectiveCap, 'Member without an override should inherit the group default cap');
        System.assertEquals(1, row1.periodCount, 'Member 1 has one Assigned log in the current Daily window');

        WSM_RR_AdminController.MemberRow row2 = rowsByMemberId.get(m2.Id);
        System.assertEquals(2, row2.effectiveCap, 'Member with an override should use it instead of the group default');
        System.assertEquals(0, row2.periodCount, 'Member 2 has no Assigned logs');
    }

    @IsTest
    static void testGetGroupDetailPeriodCountExcludesLogsOutsideDailyWindow() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Least Assigned');
        g.WSM_Period__c = 'Daily';
        update g;
        WSM_Round_Robin_Member__c m = seedMember(g.Id, users[0].Id, 10);

        WSM_Assignment_Log__c logToday = seedLog(g.Id, m.Id, users[0].Id, 'Assigned');
        WSM_Assignment_Log__c logOld = seedLog(g.Id, m.Id, users[0].Id, 'Assigned');
        Test.setCreatedDate(logOld.Id, Datetime.now().addDays(-2));

        Test.startTest();
        WSM_RR_AdminController.GroupDetail detail = WSM_RR_AdminController.getGroupDetail(g.Id);
        Test.stopTest();

        System.assertEquals(1, detail.members.size(), 'One member expected');
        System.assertEquals(
            1,
            detail.members[0].periodCount,
            'Only the log created within the current Daily window should count'
        );
    }

    // ------------------------------------------------------------------
    // saveGroup
    // ------------------------------------------------------------------

    @IsTest
    static void testSaveGroupAutoSlugsDeveloperNameWhenBlank() {
        Map<String, Object> payload = new Map<String, Object>{
            'name' => 'My Cool Group!!',
            'algorithm' => 'Strict Rotation',
            'capacityMode' => 'None',
            'period' => 'Daily',
            'calibration' => 'Median',
            'active' => true
        };

        Test.startTest();
        Id newId = WSM_RR_AdminController.saveGroup(JSON.serialize(payload));
        Test.stopTest();

        WSM_Round_Robin_Group__c saved = [SELECT WSM_Developer_Name__c FROM WSM_Round_Robin_Group__c WHERE Id = :newId];
        System.assertEquals('my_cool_group', saved.WSM_Developer_Name__c, 'Blank developer name should auto-slug from the name, collapsing punctuation/whitespace into single underscores and trimming edges');
    }

    @IsTest
    static void testSaveGroupRejectsDuplicateDeveloperName() {
        WSM_Round_Robin_Group__c existing = new WSM_Round_Robin_Group__c(
            Name = 'Existing Group',
            WSM_Developer_Name__c = 'dup_key_test'
        );
        insert existing;

        Map<String, Object> payload = new Map<String, Object>{
            'name' => 'Dup Key Test',
            'algorithm' => 'Strict Rotation'
        };

        Boolean threw = false;
        Test.startTest();
        try {
            WSM_RR_AdminController.saveGroup(JSON.serialize(payload));
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('already exists'),
                'Expected a friendly duplicate-developer-name error, got: ' + e.getMessage()
            );
        }
        Test.stopTest();

        System.assert(threw, 'Saving a group whose slug collides with an existing developer name should be blocked');
    }

    @IsTest
    static void testSaveGroupUpdatesExistingGroupInPlace() {
        Map<String, Object> createPayload = new Map<String, Object>{
            'name' => 'Initial Name Test',
            'algorithm' => 'Strict Rotation',
            'active' => true
        };
        Id groupId = WSM_RR_AdminController.saveGroup(JSON.serialize(createPayload));
        WSM_Round_Robin_Group__c created = [SELECT WSM_Developer_Name__c FROM WSM_Round_Robin_Group__c WHERE Id = :groupId];

        Map<String, Object> updatePayload = new Map<String, Object>{
            'id' => groupId,
            'name' => 'Updated Name Test',
            'developerName' => created.WSM_Developer_Name__c,
            'algorithm' => 'Weighted',
            'active' => false
        };

        Test.startTest();
        Id returnedId = WSM_RR_AdminController.saveGroup(JSON.serialize(updatePayload));
        Test.stopTest();

        System.assertEquals(groupId, returnedId, 'Updating should return the same group Id, not create a new record');
        WSM_Round_Robin_Group__c updated = [
            SELECT Name, WSM_Developer_Name__c, WSM_Algorithm__c, WSM_Active__c
            FROM WSM_Round_Robin_Group__c
            WHERE Id = :groupId
        ];
        System.assertEquals('Updated Name Test', updated.Name, 'Name should be updated');
        System.assertEquals(created.WSM_Developer_Name__c, updated.WSM_Developer_Name__c, 'Explicit developer name should be preserved, not re-slugged');
        System.assertEquals('Weighted', updated.WSM_Algorithm__c, 'Algorithm should be updated');
        System.assertEquals(false, updated.WSM_Active__c, 'Active flag should be updated');

        List<WSM_Round_Robin_Group__c> allGroups = [SELECT Id FROM WSM_Round_Robin_Group__c WHERE Id = :groupId];
        System.assertEquals(1, allGroups.size(), 'Updating should not create a second group record');
    }

    @IsTest
    static void testSaveGroupRequiresName() {
        Map<String, Object> payload = new Map<String, Object>{ 'algorithm' => 'Strict Rotation' };

        Boolean threw = false;
        try {
            WSM_RR_AdminController.saveGroup(JSON.serialize(payload));
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'A blank name should be rejected');
    }

    // ------------------------------------------------------------------
    // setGroupActive / deleteGroup
    // ------------------------------------------------------------------

    @IsTest
    static void testSetGroupActiveTogglesFlag() {
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');

        Test.startTest();
        WSM_RR_AdminController.setGroupActive(g.Id, false);
        Test.stopTest();

        WSM_Round_Robin_Group__c reloaded = [SELECT WSM_Active__c FROM WSM_Round_Robin_Group__c WHERE Id = :g.Id];
        System.assertEquals(false, reloaded.WSM_Active__c, 'Group should now be inactive');
    }

    @IsTest
    static void testDeleteGroupCascadesMembersButPreservesLogsWithNulledLookups() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        WSM_Round_Robin_Member__c m = seedMember(g.Id, users[0].Id, 10);
        WSM_Assignment_Log__c log = seedLog(g.Id, m.Id, users[0].Id, 'Assigned');

        Test.startTest();
        WSM_RR_AdminController.deleteGroup(g.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM WSM_Round_Robin_Group__c WHERE Id = :g.Id], 'Group should be deleted');
        System.assertEquals(0, [SELECT COUNT() FROM WSM_Round_Robin_Member__c WHERE Id = :m.Id], 'Member should cascade-delete with the group (Master-Detail)');

        WSM_Assignment_Log__c reloadedLog = [SELECT WSM_Group__c, WSM_Member__c FROM WSM_Assignment_Log__c WHERE Id = :log.Id];
        System.assertEquals(null, reloadedLog.WSM_Group__c, 'Log should survive group deletion with its group lookup nulled (SetNull)');
        System.assertEquals(null, reloadedLog.WSM_Member__c, 'Log should survive member cascade-delete with its member lookup nulled (SetNull)');
    }

    // ------------------------------------------------------------------
    // searchUsers
    // ------------------------------------------------------------------

    @IsTest
    static void testSearchUsersExcludesExistingMembersAndFiltersByTerm() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        seedMember(g.Id, users[0].Id, 10);

        Test.startTest();
        List<WSM_RR_AdminController.UserOption> results = WSM_RR_AdminController.searchUsers('RRTest', g.Id);
        Test.stopTest();

        Set<Id> resultIds = new Set<Id>();
        for (WSM_RR_AdminController.UserOption opt : results) {
            resultIds.add(opt.userId);
        }
        System.assert(!resultIds.contains(users[0].Id), 'Existing member should be excluded from search results');
        System.assert(resultIds.contains(users[1].Id), 'Non-member matching the term should be included');
    }

    @IsTest
    static void testSearchUsersBlankTermReturnsUpToTwentyAlphabetical() {
        Test.startTest();
        List<WSM_RR_AdminController.UserOption> results = WSM_RR_AdminController.searchUsers('', null);
        Test.stopTest();

        System.assert(results.size() <= 20, 'Blank term should cap results at 20');
        System.assert(!results.isEmpty(), 'Blank term should still return active users');
    }

    // ------------------------------------------------------------------
    // addMembers
    // ------------------------------------------------------------------

    @IsTest
    static void testAddMembersInsertsWithIncrementingSortOrder() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');

        Test.startTest();
        List<Id> firstBatchIds = WSM_RR_AdminController.addMembers(g.Id, new List<Id>{ users[0].Id, users[1].Id });
        List<Id> secondBatchIds = WSM_RR_AdminController.addMembers(g.Id, new List<Id>{ users[2].Id });
        Test.stopTest();

        System.assertEquals(2, firstBatchIds.size(), 'Two members should be inserted in the first batch');
        System.assertEquals(1, secondBatchIds.size(), 'One member should be inserted in the second batch');

        Map<Id, WSM_Round_Robin_Member__c> membersByUser = new Map<Id, WSM_Round_Robin_Member__c>();
        for (WSM_Round_Robin_Member__c m : [
            SELECT Id, WSM_User__c, WSM_Weight__c, WSM_Active__c, WSM_Sort_Order__c
            FROM WSM_Round_Robin_Member__c
            WHERE WSM_Group__c = :g.Id
        ]) {
            membersByUser.put(m.WSM_User__c, m);
        }

        System.assertEquals(1, membersByUser.get(users[0].Id).WSM_Weight__c, 'New members should default to weight 1');
        System.assertEquals(true, membersByUser.get(users[0].Id).WSM_Active__c, 'New members should default to active');
        System.assertEquals(10, membersByUser.get(users[0].Id).WSM_Sort_Order__c.intValue(), 'First member should get sort order 10');
        System.assertEquals(20, membersByUser.get(users[1].Id).WSM_Sort_Order__c.intValue(), 'Second member should get sort order 20');
        System.assertEquals(30, membersByUser.get(users[2].Id).WSM_Sort_Order__c.intValue(), 'Third member added later should continue from the existing max + 10');
    }

    // ------------------------------------------------------------------
    // updateMembers, absent vs. present-null field patching
    // ------------------------------------------------------------------

    @IsTest
    static void testUpdateMembersOnlyTouchesFieldsExplicitlyProvided() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Weighted');
        WSM_Round_Robin_Member__c m = seedMember(g.Id, users[0].Id, 10);
        m.WSM_Weight__c = 5;
        m.WSM_Cap_Override__c = 3;
        m.WSM_Active__c = true;
        update m;

        // Only "weight" is present, active and capOverride must be left untouched.
        String onlyWeightJson = '[{"memberId":"' + m.Id + '","weight":9}]';
        Test.startTest();
        WSM_RR_AdminController.updateMembers(onlyWeightJson);
        Test.stopTest();

        WSM_Round_Robin_Member__c afterFirstUpdate = [
            SELECT WSM_Weight__c, WSM_Cap_Override__c, WSM_Active__c
            FROM WSM_Round_Robin_Member__c
            WHERE Id = :m.Id
        ];
        System.assertEquals(9, afterFirstUpdate.WSM_Weight__c, 'Weight should be updated');
        System.assertEquals(3, afterFirstUpdate.WSM_Cap_Override__c, 'Cap override should be untouched because its key was absent');
        System.assertEquals(true, afterFirstUpdate.WSM_Active__c, 'Active should be untouched because its key was absent');

        // Now "capOverride" is present with an explicit null, it must be CLEARED,
        // while weight (absent this time) must remain untouched.
        String clearCapJson = '[{"memberId":"' + m.Id + '","capOverride":null}]';
        WSM_RR_AdminController.updateMembers(clearCapJson);

        WSM_Round_Robin_Member__c afterSecondUpdate = [
            SELECT WSM_Weight__c, WSM_Cap_Override__c
            FROM WSM_Round_Robin_Member__c
            WHERE Id = :m.Id
        ];
        System.assertEquals(null, afterSecondUpdate.WSM_Cap_Override__c, 'Explicit null capOverride should clear the field');
        System.assertEquals(9, afterSecondUpdate.WSM_Weight__c, 'Weight should remain untouched by the second call');
    }

    @IsTest
    static void testUpdateMembersHandlesBooleanAndDateFields() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        WSM_Round_Robin_Member__c m = seedMember(g.Id, users[0].Id, 10);

        String json = '[{"memberId":"' + m.Id + '","active":false,"isManager":true,"oooStart":"2026-09-01","oooReturn":"2026-09-08"}]';

        Test.startTest();
        WSM_RR_AdminController.updateMembers(json);
        Test.stopTest();

        WSM_Round_Robin_Member__c reloaded = [
            SELECT WSM_Active__c, WSM_Is_Manager__c, WSM_OOO_Start_Date__c, WSM_OOO_Return_Date__c
            FROM WSM_Round_Robin_Member__c
            WHERE Id = :m.Id
        ];
        System.assertEquals(false, reloaded.WSM_Active__c, 'Active should be set to false');
        System.assertEquals(true, reloaded.WSM_Is_Manager__c, 'Is Manager should be set to true');
        System.assertEquals(Date.newInstance(2026, 9, 1), reloaded.WSM_OOO_Start_Date__c, 'OOO start date should parse correctly');
        System.assertEquals(Date.newInstance(2026, 9, 8), reloaded.WSM_OOO_Return_Date__c, 'OOO return date should parse correctly');

        String clearDatesJson = '[{"memberId":"' + m.Id + '","oooStart":null,"oooReturn":null}]';
        WSM_RR_AdminController.updateMembers(clearDatesJson);
        WSM_Round_Robin_Member__c cleared = [
            SELECT WSM_OOO_Start_Date__c, WSM_OOO_Return_Date__c
            FROM WSM_Round_Robin_Member__c
            WHERE Id = :m.Id
        ];
        System.assertEquals(null, cleared.WSM_OOO_Start_Date__c, 'Explicit null should clear OOO start date');
        System.assertEquals(null, cleared.WSM_OOO_Return_Date__c, 'Explicit null should clear OOO return date');
    }

    @IsTest
    static void testUpdateMembersRequiresMemberId() {
        Boolean threw = false;
        try {
            WSM_RR_AdminController.updateMembers('[{"weight":5}]');
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(e.getMessage().contains('memberId'), 'Error should mention the missing memberId');
        }
        System.assert(threw, 'A member update without a memberId should be rejected');
    }

    // ------------------------------------------------------------------
    // removeMember / reorderMembers / resetCounters
    // ------------------------------------------------------------------

    @IsTest
    static void testRemoveMemberDeletesSeat() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        WSM_Round_Robin_Member__c m = seedMember(g.Id, users[0].Id, 10);

        Test.startTest();
        WSM_RR_AdminController.removeMember(m.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM WSM_Round_Robin_Member__c WHERE Id = :m.Id], 'Member should be removed');
    }

    @IsTest
    static void testReorderMembersRewritesSortOrder() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        WSM_Round_Robin_Member__c m1 = seedMember(g.Id, users[0].Id, 10);
        WSM_Round_Robin_Member__c m2 = seedMember(g.Id, users[1].Id, 20);
        WSM_Round_Robin_Member__c m3 = seedMember(g.Id, users[2].Id, 30);

        Test.startTest();
        WSM_RR_AdminController.reorderMembers(g.Id, new List<Id>{ m3.Id, m1.Id, m2.Id });
        Test.stopTest();

        Map<Id, WSM_Round_Robin_Member__c> reloaded = new Map<Id, WSM_Round_Robin_Member__c>([
            SELECT Id, WSM_Sort_Order__c FROM WSM_Round_Robin_Member__c WHERE WSM_Group__c = :g.Id
        ]);
        System.assertEquals(10, reloaded.get(m3.Id).WSM_Sort_Order__c.intValue(), 'm3 should now be first');
        System.assertEquals(20, reloaded.get(m1.Id).WSM_Sort_Order__c.intValue(), 'm1 should now be second');
        System.assertEquals(30, reloaded.get(m2.Id).WSM_Sort_Order__c.intValue(), 'm2 should now be third');
    }

    @IsTest
    static void testReorderMembersRejectsMemberFromDifferentGroup() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g1 = seedGroup('Strict Rotation');
        WSM_Round_Robin_Group__c g2 = seedGroup('Strict Rotation');
        WSM_Round_Robin_Member__c m1 = seedMember(g1.Id, users[0].Id, 10);
        WSM_Round_Robin_Member__c m2 = seedMember(g2.Id, users[1].Id, 10);

        Boolean threw = false;
        try {
            WSM_RR_AdminController.reorderMembers(g1.Id, new List<Id>{ m1.Id, m2.Id });
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Reordering with a member from a different group should be rejected');
    }

    @IsTest
    static void testResetCountersClearsRotationStateButKeepsLogs() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Weighted');
        WSM_Round_Robin_Member__c m = seedMember(g.Id, users[0].Id, 10);
        m.WSM_Rotation_Value__c = 123.45;
        m.WSM_Last_Assigned__c = Datetime.now();
        update m;
        seedLog(g.Id, m.Id, users[0].Id, 'Assigned');

        Integer logCountBefore = [SELECT COUNT() FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :g.Id];

        Test.startTest();
        WSM_RR_AdminController.resetCounters(g.Id);
        Test.stopTest();

        WSM_Round_Robin_Member__c reloaded = [
            SELECT WSM_Rotation_Value__c, WSM_Last_Assigned__c
            FROM WSM_Round_Robin_Member__c
            WHERE Id = :m.Id
        ];
        System.assertEquals(null, reloaded.WSM_Rotation_Value__c, 'Rotation value should be cleared');
        System.assertEquals(null, reloaded.WSM_Last_Assigned__c, 'Last assigned should be cleared');

        Integer logCountAfter = [SELECT COUNT() FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :g.Id];
        System.assertEquals(logCountBefore, logCountAfter, 'Reset Counters must never touch assignment logs');
    }

    // ------------------------------------------------------------------
    // getRecentAssignments
    // ------------------------------------------------------------------

    @IsTest
    static void testGetRecentAssignmentsRespectsLimitAndOrder() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        WSM_Round_Robin_Member__c m = seedMember(g.Id, users[0].Id, 10);

        WSM_Assignment_Log__c log1 = seedLog(g.Id, m.Id, users[0].Id, 'Assigned');
        Test.setCreatedDate(log1.Id, Datetime.now().addMinutes(-30));
        WSM_Assignment_Log__c log2 = seedLog(g.Id, m.Id, users[0].Id, 'Assigned');
        Test.setCreatedDate(log2.Id, Datetime.now().addMinutes(-20));
        WSM_Assignment_Log__c log3 = seedLog(g.Id, m.Id, users[0].Id, 'Assigned');
        Test.setCreatedDate(log3.Id, Datetime.now().addMinutes(-10));

        Test.startTest();
        List<WSM_RR_AdminController.LogEntry> limited = WSM_RR_AdminController.getRecentAssignments(g.Id, 2);
        List<WSM_RR_AdminController.LogEntry> defaulted = WSM_RR_AdminController.getRecentAssignments(g.Id, null);
        Test.stopTest();

        System.assertEquals(2, limited.size(), 'Explicit limit should be respected');
        System.assertEquals(log3.Id, limited[0].logId, 'Most recent log should come first');
        System.assertEquals(log2.Id, limited[1].logId, 'Second most recent log should come second');
        System.assertEquals('Assigned', limited[0].status, 'Status should be mapped');
        System.assertEquals(users[0].Id, limited[0].assignedUserId, 'Assigned user id should be mapped');
        System.assertEquals(users[0].Name, limited[0].assignedUserName, 'Assigned user name should resolve');
        System.assertEquals(users[0].Name, limited[0].memberUserName, 'Member user name should resolve');
        System.assertEquals('Unit Test', limited[0].context, 'Context should be mapped');
        System.assertEquals('test detail', limited[0].detail, 'Detail should be mapped');

        System.assertEquals(3, defaulted.size(), 'Null limit should fall back to the default (25), returning all 3 seeded logs');
    }

    // ------------------------------------------------------------------
    // simulate, dry-run vs. commit
    // ------------------------------------------------------------------

    @IsTest
    static void testSimulateDryRunProducesVerdictsAndPerformsNoDml() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        WSM_Round_Robin_Member__c m1 = seedMember(g.Id, users[0].Id, 10);
        WSM_Round_Robin_Member__c m2 = seedMember(g.Id, users[1].Id, 20);

        Integer logCountBefore = [SELECT COUNT() FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :g.Id];

        Test.startTest();
        WSM_RR_AdminController.SimulationResult sim = WSM_RR_AdminController.simulate(g.Id, false);
        Test.stopTest();

        System.assertEquals(false, sim.committed, 'Dry-run should report committed = false');
        System.assertEquals(null, sim.logId, 'Dry-run should not produce a log id');
        System.assertNotEquals(null, sim.verdicts, 'Dry-run should return verdicts');
        System.assertEquals(2, sim.verdicts.size(), 'One verdict per member');

        Integer logCountAfter = [SELECT COUNT() FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :g.Id];
        System.assertEquals(logCountBefore, logCountAfter, 'Dry-run simulate must not write any assignment logs');

        WSM_Round_Robin_Member__c reloaded1 = [SELECT WSM_Last_Assigned__c, WSM_Rotation_Value__c FROM WSM_Round_Robin_Member__c WHERE Id = :m1.Id];
        System.assertEquals(null, reloaded1.WSM_Last_Assigned__c, 'Dry-run must not mutate member rotation state');
    }

    @IsTest
    static void testSimulateCommitWritesAssignmentAndReturnsStatus() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        WSM_Round_Robin_Member__c m = seedMember(g.Id, users[0].Id, 10);

        Integer logCountBefore = [SELECT COUNT() FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :g.Id];

        Test.startTest();
        WSM_RR_AdminController.SimulationResult sim = WSM_RR_AdminController.simulate(g.Id, true);
        Test.stopTest();

        System.assertEquals(true, sim.committed, 'Commit run should report committed = true');
        System.assertEquals('ASSIGNED', sim.status, 'The sole active member should be assigned');
        System.assertEquals(users[0].Id, sim.wouldAssignUserId, 'Assigned user id should match the sole member');
        System.assertEquals(users[0].Name, sim.wouldAssignUserName, 'Assigned user name should resolve');
        System.assertNotEquals(null, sim.logId, 'A committed assignment must produce a log id');

        WSM_Assignment_Log__c committedLog = [SELECT WSM_Status__c, WSM_Group__c FROM WSM_Assignment_Log__c WHERE Id = :sim.logId];
        System.assertEquals('Assigned', committedLog.WSM_Status__c, 'The log written by assign() should be Assigned');
        System.assertEquals(g.Id, committedLog.WSM_Group__c, 'The log should belong to the simulated group');

        Integer logCountAfter = [SELECT COUNT() FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :g.Id];
        System.assertEquals(logCountBefore + 1, logCountAfter, 'Commit run should add exactly one log row');
    }

    @IsTest
    static void testSimulateDryRunReportsNoEligibleMembersWithSkipReason() {
        List<User> users = testUsers();
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        WSM_Round_Robin_Member__c m = seedMember(g.Id, users[0].Id, 10);
        m.WSM_Active__c = false;
        update m;

        Test.startTest();
        WSM_RR_AdminController.SimulationResult sim = WSM_RR_AdminController.simulate(g.Id, false);
        Test.stopTest();

        System.assertEquals('NO_ELIGIBLE_MEMBERS', sim.status, 'No active members means nothing would be assigned');
        System.assertEquals(null, sim.wouldAssignUserId, 'No user should be identified for assignment');
        System.assertEquals(1, sim.verdicts.size(), 'One verdict for the sole (ineligible) member');
        System.assertEquals(false, sim.verdicts[0].eligible, 'The inactive member should be ineligible');
        System.assertEquals('Inactive', sim.verdicts[0].skipReason, 'Skip reason should explain why the member was excluded');
    }

    // ------------------------------------------------------------------
    // Capacity Queries
    // ------------------------------------------------------------------

    private static String capacityJson(Id groupId, Id existingId, String label, String objectName,
            String role, Integer cap, String filterLogic, List<Map<String, Object>> filters) {
        Map<String, Object> payload = new Map<String, Object>{
            'groupId' => groupId,
            'label' => label,
            'objectName' => objectName,
            'role' => role,
            'cap' => cap,
            'filterLogic' => filterLogic,
            'active' => true,
            'filters' => filters
        };
        if (existingId != null) {
            payload.put('id', existingId);
        }
        return JSON.serialize(payload);
    }

    private static Map<String, Object> filterMap(Integer filterNumber, String fieldName, String operator, String value) {
        return new Map<String, Object>{
            'filterNumber' => filterNumber,
            'fieldName' => fieldName,
            'operator' => operator,
            'valueSource' => 'Literal',
            'value' => value
        };
    }

    @IsTest
    static void testSaveAndGetCapacityQueryRoundTripsWithFilters() {
        WSM_Round_Robin_Group__c g = seedGroup('Least Loaded');

        Test.startTest();
        Id capacityId = WSM_RR_AdminController.saveCapacityQuery(capacityJson(
            g.Id, null, 'Open Accounts', 'Account', 'Cap and Load Metric', 25, '1 AND 2',
            new List<Map<String, Object>>{
                filterMap(1, 'Name', 'starts with', 'Acme'),
                filterMap(2, 'Industry', 'equals', 'Banking')
            }));
        List<WSM_RR_AdminController.CapacityQueryRow> rows = WSM_RR_AdminController.getCapacityQueries(g.Id);
        Test.stopTest();

        System.assertNotEquals(null, capacityId, 'Saving must return the new record Id.');
        System.assertEquals(1, rows.size(), 'The group must report its one capacity query.');
        WSM_RR_AdminController.CapacityQueryRow row = rows[0];
        System.assertEquals('Open Accounts', row.label, 'The label must round-trip.');
        System.assertEquals(25, row.cap, 'The cap must round-trip.');
        System.assertEquals('1 AND 2', row.filterLogic, 'The filter logic must round-trip.');
        System.assertEquals(2, row.filters.size(), 'Both filters must round-trip.');
        System.assertEquals(true, row.valid, 'A well-formed query must come back valid. Reason: ' + row.invalidReason);
    }

    @IsTest
    static void testGetCapacityQueriesReportsTheCompilerReason() {
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');

        Test.startTest();
        WSM_RR_AdminController.saveCapacityQuery(capacityJson(
            g.Id, null, 'Broken', 'Account', 'Cap', 5, null,
            new List<Map<String, Object>>{ filterMap(1, 'NotAField__c', 'equals', 'x') }));
        List<WSM_RR_AdminController.CapacityQueryRow> rows = WSM_RR_AdminController.getCapacityQueries(g.Id);
        Test.stopTest();

        System.assertEquals(false, rows[0].valid, 'A field that does not exist must come back invalid.');
        System.assert(rows[0].invalidReason.contains('does not exist'),
            'The editor needs the reason, not just a failure flag: ' + rows[0].invalidReason);
    }

    @IsTest
    static void testSaveCapacityQueryReplacesFiltersRatherThanAppending() {
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        Id capacityId = WSM_RR_AdminController.saveCapacityQuery(capacityJson(
            g.Id, null, 'Counts', 'Account', 'Cap', 5, null,
            new List<Map<String, Object>>{
                filterMap(1, 'Name', 'equals', 'a'),
                filterMap(2, 'Industry', 'equals', 'Banking')
            }));

        Test.startTest();
        WSM_RR_AdminController.saveCapacityQuery(capacityJson(
            g.Id, capacityId, 'Counts', 'Account', 'Cap', 5, null,
            new List<Map<String, Object>>{ filterMap(1, 'Name', 'equals', 'b') }));
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM WSM_Capacity_Filter__c WHERE WSM_Capacity_Query__c = :capacityId],
            'Filters are replaced wholesale on save. Appending would leave Filter Logic pointing at rows the admin thought they deleted.');
        System.assertEquals(1, [SELECT COUNT() FROM WSM_Capacity_Query__c WHERE WSM_Group__c = :g.Id],
            'Re-saving with an Id must update in place, not create a second row.');
    }

    @IsTest
    static void testSaveCapacityQueryAutoNumbersFiltersWhenOmitted() {
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');

        Test.startTest();
        Id capacityId = WSM_RR_AdminController.saveCapacityQuery(capacityJson(
            g.Id, null, 'Counts', 'Account', 'Cap', 5, null,
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'fieldName' => 'Name', 'operator' => 'equals', 'value' => 'a' },
                new Map<String, Object>{ 'fieldName' => 'Industry', 'operator' => 'equals', 'value' => 'Banking' }
            }));
        Test.stopTest();

        List<WSM_Capacity_Filter__c> filters = [
            SELECT WSM_Filter_Number__c FROM WSM_Capacity_Filter__c
            WHERE WSM_Capacity_Query__c = :capacityId ORDER BY WSM_Filter_Number__c];
        System.assertEquals(1, filters[0].WSM_Filter_Number__c, 'A filter with no number must fall back to its position.');
        System.assertEquals(2, filters[1].WSM_Filter_Number__c, 'A filter with no number must fall back to its position.');
    }

    @IsTest
    static void testSaveCapacityQueryRequiresGroupAndLabel() {
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');

        Test.startTest();
        try {
            WSM_RR_AdminController.saveCapacityQuery(capacityJson(null, null, 'X', 'Account', 'Cap', 1, null, null));
            System.assert(false, 'A capacity query with no group must be rejected.');
        } catch (AuraHandledException expected) {
            System.assert(true);
        }
        try {
            WSM_RR_AdminController.saveCapacityQuery(capacityJson(g.Id, null, '  ', 'Account', 'Cap', 1, null, null));
            System.assert(false, 'A capacity query with no label must be rejected.');
        } catch (AuraHandledException expected) {
            System.assert(true);
        }
        Test.stopTest();
    }

    @IsTest
    static void testDeleteCapacityQueryCascadesItsFilters() {
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        Id capacityId = WSM_RR_AdminController.saveCapacityQuery(capacityJson(
            g.Id, null, 'Counts', 'Account', 'Cap', 5, null,
            new List<Map<String, Object>>{ filterMap(1, 'Name', 'equals', 'a') }));

        Test.startTest();
        WSM_RR_AdminController.deleteCapacityQuery(capacityId);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM WSM_Capacity_Query__c WHERE Id = :capacityId]);
        System.assertEquals(0, [SELECT COUNT() FROM WSM_Capacity_Filter__c],
            'Master-detail must take the filters with the parent.');
    }

    @IsTest
    static void testValidateCapacityQueryChecksWithoutSaving() {
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');

        Test.startTest();
        WSM_RR_AdminController.CapacityQueryRow good = WSM_RR_AdminController.validateCapacityQuery(capacityJson(
            g.Id, null, 'Good', 'Account', 'Cap', 5, null,
            new List<Map<String, Object>>{ filterMap(1, 'Name', 'equals', 'a') }));
        WSM_RR_AdminController.CapacityQueryRow bad = WSM_RR_AdminController.validateCapacityQuery(capacityJson(
            g.Id, null, 'Bad', 'Nope__c', 'Cap', 5, null,
            new List<Map<String, Object>>{ filterMap(1, 'Name', 'equals', 'a') }));
        Test.stopTest();

        System.assertEquals(true, good.valid, 'A valid draft must validate. Reason: ' + good.invalidReason);
        System.assertEquals(false, bad.valid, 'An unknown object must not validate.');
        System.assertEquals(0, [SELECT COUNT() FROM WSM_Capacity_Query__c],
            'Validating a draft must not write anything; the admin has not pressed save yet.');
    }

    @IsTest
    static void testDescribeCountableObjectsIncludesAccountAndSortsByLabel() {
        Test.startTest();
        List<WSM_RR_AdminController.ObjectOption> options = WSM_RR_AdminController.describeCountableObjects();
        Test.stopTest();

        Boolean foundAccount = false;
        for (WSM_RR_AdminController.ObjectOption option : options) {
            if (option.apiName == 'Account') {
                foundAccount = true;
            }
        }
        System.assert(foundAccount, 'Account must be offered as something an admin can count.');
        System.assert(options.size() > 1, 'More than one object must be offered.');
        for (Integer i = 1; i < options.size(); i++) {
            System.assert(options[i - 1].label.compareTo(options[i].label) <= 0,
                'Options must be sorted by label so the dropdown is navigable.');
        }
    }

    @IsTest
    static void testDescribeFilterableFieldsCarriesTypesAndPicklistValues() {
        Test.startTest();
        List<WSM_RR_AdminController.FieldOption> fields = WSM_RR_AdminController.describeFilterableFields('Account');
        Test.stopTest();

        Map<String, WSM_RR_AdminController.FieldOption> byName = new Map<String, WSM_RR_AdminController.FieldOption>();
        for (WSM_RR_AdminController.FieldOption f : fields) {
            byName.put(f.apiName, f);
        }
        System.assert(byName.containsKey('Name'), 'A filterable standard field must be offered.');
        System.assertEquals('STRING', byName.get('Name').fieldType, 'The editor needs the type to pick sensible operators.');
        System.assert(byName.containsKey('Industry'), 'Industry must be offered.');
        System.assert(byName.get('Industry').picklistValues.size() > 0,
            'Picklist values must come back so the editor can offer a value picker instead of free text.');
        System.assertEquals(true, byName.get('Industry').groupable,
            'Groupability must be reported, because only a groupable field can take its value from the routed record.');
    }

    @IsTest
    static void testDescribeFilterableFieldsRejectsAnUnknownObject() {
        Test.startTest();
        try {
            WSM_RR_AdminController.describeFilterableFields('NotAnObjectAnywhere__c');
            System.assert(false, 'An unknown object must be rejected.');
        } catch (AuraHandledException expected) {
            System.assert(true);
        }
        System.assertEquals(0, WSM_RR_AdminController.describeFilterableFields('').size(),
            'A blank object name must return nothing rather than throwing.');
        Test.stopTest();
    }

    @IsTest
    static void testUpdateMembersWritesTier() {
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        List<User> users = testUsers();
        WSM_Round_Robin_Member__c m = seedMember(g.Id, users[0].Id, 0);

        Test.startTest();
        WSM_RR_AdminController.updateMembers(JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'memberId' => m.Id, 'tier' => 2 }
        }));
        Test.stopTest();

        System.assertEquals(2, [SELECT WSM_Tier__c FROM WSM_Round_Robin_Member__c WHERE Id = :m.Id].WSM_Tier__c,
            'The editor must be able to move someone onto the overflow bench.');
    }

    @IsTest
    static void testGetGroupDetailReportsTierAndDefaultsBlankToOne() {
        WSM_Round_Robin_Group__c g = seedGroup('Strict Rotation');
        List<User> users = testUsers();
        WSM_Round_Robin_Member__c first = seedMember(g.Id, users[0].Id, 0);
        WSM_Round_Robin_Member__c second = seedMember(g.Id, users[1].Id, 1);
        second.WSM_Tier__c = 3;
        update second;
        first.WSM_Tier__c = null;
        update first;

        Test.startTest();
        WSM_RR_AdminController.GroupDetail detail = WSM_RR_AdminController.getGroupDetail(g.Id);
        Test.stopTest();

        Map<Id, Integer> tierByMember = new Map<Id, Integer>();
        for (WSM_RR_AdminController.MemberRow row : detail.members) {
            tierByMember.put(row.memberId, row.tier);
        }
        System.assertEquals(1, tierByMember.get(first.Id), 'A blank Tier must be reported as 1, matching how the engine reads it.');
        System.assertEquals(3, tierByMember.get(second.Id), 'A real Tier must be reported as-is.');
    }

    @IsTest
    static void testSimulateSurfacesCapacityReadingsWarningsAndTier() {
        WSM_Round_Robin_Group__c g = seedGroup('Least Loaded');
        List<User> users = testUsers();
        seedMember(g.Id, users[0].Id, 0);
        WSM_RR_AdminController.saveCapacityQuery(capacityJson(
            g.Id, null, 'Book Size', 'Account', 'Cap and Load Metric', 10, null,
            new List<Map<String, Object>>{ filterMap(1, 'Name', 'starts with', 'RRSim') }));
        WSM_RR_AdminController.saveCapacityQuery(capacityJson(
            g.Id, null, 'Broken One', 'Account', 'Cap', 10, null,
            new List<Map<String, Object>>{ filterMap(1, 'NopeField__c', 'equals', 'x') }));
        insert new Account(Name = 'RRSim One', OwnerId = users[0].Id);

        Test.startTest();
        WSM_RR_AdminController.SimulationResult result = WSM_RR_AdminController.simulate(g.Id, false);
        Test.stopTest();

        System.assertEquals('ASSIGNED', result.status, 'One member under the cap must be assignable.');
        System.assertEquals(1, result.assignedFromTier, 'The pick must be reported as coming from tier 1.');
        System.assertEquals(1, result.verdicts.size());
        WSM_RR_AdminController.Verdict verdict = result.verdicts[0];
        System.assertEquals(1, verdict.tier, 'The verdict must carry the tier.');
        System.assertEquals(1, verdict.capacity.size(), 'Only the compiling capacity query can produce a reading.');
        System.assertEquals('Book Size', verdict.capacity[0].label);
        System.assertEquals(1, verdict.capacity[0].count, 'The reading must show the real count off the org.');
        System.assertEquals(1, verdict.externalLoad, 'The load must be exposed so the simulator can explain the ranking.');
        System.assertEquals(1, result.warnings.size(), 'The broken capacity query must be reported to the admin.');
        System.assert(result.warnings[0].contains('Broken One'), 'The warning must name it: ' + result.warnings[0]);
    }
}
