/**
 * Integration coverage for WSM_RoundRobinEngine against real records: locking, bulk
 * correctness, capacity, out-of-office, period-window resets, and the concurrency
 * retry/timeout seam. Real assertions throughout, see WSM_Strategies_Test for why this
 * suite is exempt from the org's coverage-only convention.
 */
@isTest
private class WSM_RoundRobinEngine_Test {

    @isTest
    static void groupNotFound_whenGroupDoesNotExist() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Ghost Group', 'Strict Rotation');
        Id ghostId = grp.Id;
        delete grp;

        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{ new WSM_RRRequest(ghostId) });

        System.assertEquals(1, results.size());
        System.assertEquals(WSM_RRResult.STATUS_GROUP_NOT_FOUND, results[0].status);
        System.assertEquals(false, results[0].isSuccess);
        List<WSM_Assignment_Log__c> logs = [SELECT Id, WSM_Status__c FROM WSM_Assignment_Log__c WHERE WSM_Status__c = 'Error'];
        System.assertEquals(1, logs.size(), 'A GROUP_NOT_FOUND outcome must still write a log row.');
    }

    @isTest
    static void groupInactive_returnsGroupInactiveAndLogs() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Paused Group', 'Strict Rotation');
        grp.WSM_Active__c = false;
        update grp;
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        WSM_RRResult result = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        System.assertEquals(WSM_RRResult.STATUS_GROUP_INACTIVE, result.status);
        System.assertEquals(1, [SELECT COUNT() FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id]);
    }

    @isTest
    static void bulk200Requests_oneGroupOfFive_evenDistribution_fixedFootprint() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Bulk Group', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(5);
        List<Id> userIds = new List<Id>();
        for (User u : users) {
            userIds.add(u.Id);
        }
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, userIds);

        List<WSM_RRRequest> requests = new List<WSM_RRRequest>();
        for (Integer i = 0; i < 200; i++) {
            requests.add(new WSM_RRRequest(grp.Id));
        }

        // Measured within a single governor-limit context, Test.startTest()/stopTest()
        // would reset these counters and make a before/after delta across that boundary
        // meaningless, so this deliberately doesn't use them.
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();

        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(requests);

        System.assertEquals(200, results.size());
        Map<Id, Integer> countsByUser = new Map<Id, Integer>();
        for (WSM_RRResult r : results) {
            System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, r.status);
            Integer running = countsByUser.containsKey(r.userId) ? countsByUser.get(r.userId) : 0;
            countsByUser.put(r.userId, running + 1);
        }
        System.assertEquals(5, countsByUser.size(), 'All five members should have been used.');
        for (Id userId : userIds) {
            System.assertEquals(40, countsByUser.get(userId), 'Strict Rotation over a clean pool of 5 for 200 picks must land exactly 40 each.');
        }

        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        System.assert(queriesUsed <= 4, 'Expected a fixed, small query footprint regardless of batch size. Used ' + queriesUsed);
        System.assertEquals(2, dmlUsed, 'Expected exactly one member update and one log insert per call, regardless of batch size.');

        for (WSM_Round_Robin_Member__c m : [SELECT WSM_Total_Assignments__c FROM WSM_Round_Robin_Member__c WHERE WSM_Group__c = :grp.Id]) {
            System.assertEquals(40, m.WSM_Total_Assignments__c,
                'Total Assignments must accumulate one increment per pick, not one per transaction.');
        }
    }

    @isTest
    static void msSequencing_multipleRequestsSameGroupInOneCall_advanceRotationAndPersistOrder() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Same Group Batch', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(3);
        List<Id> userIds = new List<Id>{ users[0].Id, users[1].Id, users[2].Id };
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, userIds);

        List<WSM_RRRequest> requests = new List<WSM_RRRequest>{
            new WSM_RRRequest(grp.Id), new WSM_RRRequest(grp.Id), new WSM_RRRequest(grp.Id)
        };
        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(requests);

        Set<Id> distinctUsers = new Set<Id>();
        for (WSM_RRResult r : results) {
            distinctUsers.add(r.userId);
        }
        System.assertEquals(3, distinctUsers.size(), 'Requesting the same group 3 times in one call with a pool of 3 must produce 3 distinct users.');

        List<WSM_Round_Robin_Member__c> members = [
            SELECT Id, WSM_Last_Assigned__c FROM WSM_Round_Robin_Member__c WHERE WSM_Group__c = :grp.Id ORDER BY WSM_Last_Assigned__c ASC
        ];
        System.assertEquals(3, members.size());
        System.assert(members[0].WSM_Last_Assigned__c < members[1].WSM_Last_Assigned__c,
            'The millisecond-sequenced stamps must be strictly increasing so replay order is preserved.');
        System.assert(members[1].WSM_Last_Assigned__c < members[2].WSM_Last_Assigned__c,
            'The millisecond-sequenced stamps must be strictly increasing so replay order is preserved.');
    }

    @isTest
    static void mixedGroupsAndAlgorithmsInOneCall() {
        WSM_Round_Robin_Group__c strictGroup = WSM_RoundRobinTestFactory.insertGroup('Mixed Strict', 'Strict Rotation');
        WSM_Round_Robin_Group__c weightedGroup = WSM_RoundRobinTestFactory.insertGroup('Mixed Weighted', 'Weighted');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(4);
        WSM_RoundRobinTestFactory.insertMembers(strictGroup.Id, new List<Id>{ users[0].Id, users[1].Id });
        WSM_RoundRobinTestFactory.insertMembers(weightedGroup.Id, new List<Id>{ users[2].Id, users[3].Id });

        Integer dmlBefore = Limits.getDmlStatements();
        List<WSM_RRRequest> requests = new List<WSM_RRRequest>{
            new WSM_RRRequest(strictGroup.Id),
            new WSM_RRRequest(weightedGroup.Id),
            new WSM_RRRequest(strictGroup.Id),
            new WSM_RRRequest(weightedGroup.Id)
        };
        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(requests);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;

        System.assertEquals(4, results.size());
        System.assertEquals(strictGroup.Id, results[0].groupId);
        System.assertEquals(weightedGroup.Id, results[1].groupId);
        System.assertEquals(strictGroup.Id, results[2].groupId);
        System.assertEquals(weightedGroup.Id, results[3].groupId);
        for (WSM_RRResult r : results) {
            System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, r.status);
        }
        System.assertEquals(2, dmlUsed, 'Two distinct groups in one call must still collapse to exactly one member update and one log insert.');
    }

    @isTest
    static void capacity_overrideZeroBlocksMember_defaultCapEventuallyBlocksTheOther() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Cap Group', 'Strict Rotation');
        grp.WSM_Capacity_Mode__c = 'Period Cap';
        grp.WSM_Default_Member_Cap__c = 2;
        update grp;

        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_Round_Robin_Member__c blockedMember = WSM_RoundRobinTestFactory.makeMember(grp.Id, users[0].Id);
        blockedMember.WSM_Cap_Override__c = 0;
        insert blockedMember;
        WSM_Round_Robin_Member__c cappedMember = WSM_RoundRobinTestFactory.insertMember(grp.Id, users[1].Id);

        WSM_RoundRobinEngine engine = new WSM_RoundRobinEngine();
        WSM_RRResult pick1 = engine.assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        WSM_RRResult pick2 = engine.assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        WSM_RRResult pick3 = engine.assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        System.assertEquals(users[1].Id, pick1.userId, 'The Cap Override = 0 member must never be picked.');
        System.assertEquals(users[1].Id, pick2.userId, 'Still under its cap of 2, the same member should be picked again.');
        System.assertEquals(WSM_RRResult.STATUS_NO_ELIGIBLE_MEMBERS, pick3.status,
            'Once the only eligible member hits its cap, and the other is permanently blocked, the pool is empty with no fallback configured.');
    }

    @isTest
    static void capacity_midBatchConsumptionBindsWithinOneCall() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Mid Batch Cap', 'Strict Rotation');
        grp.WSM_Capacity_Mode__c = 'Period Cap';
        grp.WSM_Default_Member_Cap__c = 1;
        update grp;
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        List<WSM_RRRequest> requests = new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id), new WSM_RRRequest(grp.Id) };
        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(requests);

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, results[0].status, 'The first request in the batch should succeed.');
        System.assertEquals(WSM_RRResult.STATUS_NO_ELIGIBLE_MEMBERS, results[1].status,
            'The in-memory period count from the first request in this same call must already bind the cap for the second.');
    }

    @isTest
    static void outOfOffice_boundaryDays() {
        Date today = Date.today();
        WSM_MemberState notYetStarted = memberStateWithOOO(today.addDays(1), today.addDays(5));
        WSM_MemberState firstDayOut = memberStateWithOOO(today, today.addDays(3));
        WSM_MemberState returnDayIsEligible = memberStateWithOOO(today.addDays(-5), today);
        WSM_MemberState indefiniteOut = memberStateWithOOO(today.addDays(-1), null);
        WSM_MemberState neverOut = memberStateWithOOO(null, null);

        WSM_OutOfOfficeRule rule = new WSM_OutOfOfficeRule();
        WSM_GroupState dummyGroup = new WSM_GroupState(new WSM_Round_Robin_Group__c());

        System.assertEquals(null, rule.evaluate(notYetStarted, dummyGroup, today), 'A future OOO start must not block today.');
        System.assert(rule.evaluate(firstDayOut, dummyGroup, today) != null, 'The OOO start day itself must be blocked.');
        System.assertEquals(null, rule.evaluate(returnDayIsEligible, dummyGroup, today), 'The return day itself must be eligible.');
        System.assert(rule.evaluate(indefiniteOut, dummyGroup, today) != null, 'A start date with no return date must block indefinitely.');
        System.assertEquals(null, rule.evaluate(neverOut, dummyGroup, today), 'A member with no OOO dates set must never be blocked.');
    }

    private static WSM_MemberState memberStateWithOOO(Date startDate, Date returnDate) {
        WSM_Round_Robin_Member__c rec = new WSM_Round_Robin_Member__c(
            WSM_OOO_Start_Date__c = startDate,
            WSM_OOO_Return_Date__c = returnDate,
            WSM_Active__c = true
        );
        return new WSM_MemberState(rec);
    }

    @isTest
    static void leastAssigned_periodWindowResetsViaSetCreatedDate() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('LA Window', 'Least Assigned');
        grp.WSM_Calibration__c = 'None';
        update grp;
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_Round_Robin_Member__c memberA = WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);
        WSM_Round_Robin_Member__c memberB = WSM_RoundRobinTestFactory.insertMember(grp.Id, users[1].Id);

        // Simulate a log row for member A that happened yesterday (outside today's Daily window).
        WSM_Assignment_Log__c oldLog = new WSM_Assignment_Log__c(
            WSM_Group__c = grp.Id,
            WSM_Member__c = memberA.Id,
            WSM_Assigned_User__c = users[0].Id,
            WSM_Status__c = 'Assigned'
        );
        insert oldLog;
        Test.setCreatedDate(oldLog.Id, Datetime.now().addDays(-1));

        WSM_RRResult result = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        System.assertEquals(users[0].Id, result.userId,
            'A log row from before today\'s Daily window must not count against member A, both members should show 0 for today, and the Strict-style tie falls to the eligibility/sort order, not to yesterday\'s count.');
    }

    @isTest
    static void leastAssigned_medianCalibrationVsNone_atEngineLevel() {
        WSM_Round_Robin_Group__c medianGroup = WSM_RoundRobinTestFactory.insertGroup('LA Median', 'Least Assigned');
        medianGroup.WSM_Calibration__c = 'Median';
        update medianGroup;
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(4);
        List<Id> userIds = new List<Id>{ users[0].Id, users[1].Id, users[2].Id, users[3].Id };
        List<WSM_Round_Robin_Member__c> members = WSM_RoundRobinTestFactory.insertMembers(medianGroup.Id, userIds);

        // Give three members real counts today (0, 2, 4) so the pool median (with the new
        // joiner's raw 0 folded in as [0,0,2,4]) is (0+2)/2 = 1, not 0.
        insertAssignedLog(medianGroup.Id, members[1].Id, users[1].Id);
        insertAssignedLog(medianGroup.Id, members[1].Id, users[1].Id);
        insertAssignedLog(medianGroup.Id, members[2].Id, users[2].Id);
        insertAssignedLog(medianGroup.Id, members[2].Id, users[2].Id);
        insertAssignedLog(medianGroup.Id, members[2].Id, users[2].Id);
        insertAssignedLog(medianGroup.Id, members[2].Id, users[2].Id);

        WSM_RRResult result = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{ new WSM_RRRequest(medianGroup.Id) })[0];
        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status);
        // Both members[0] (the true zero) and members[3] (also zero) are calibrated to the
        // same median and decided by the Last Assigned/Sort Order tie-break, never by
        // members[2] (raw 4) or members[1] (raw 2) which are strictly higher.
        System.assert(result.memberId == members[0].Id || result.memberId == members[3].Id,
            'Median calibration must keep the pick among the zero-count members, not promote them ahead of raw-lower counts nor fall to the highest-count members.');
    }

    private static void insertAssignedLog(Id groupId, Id memberId, Id userId) {
        insert new WSM_Assignment_Log__c(
            WSM_Group__c = groupId,
            WSM_Member__c = memberId,
            WSM_Assigned_User__c = userId,
            WSM_Status__c = 'Assigned'
        );
    }

    @isTest
    static void fallbackUser_usedWhenNoEligibleMembers() {
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Fallback Group', 'Strict Rotation');
        grp.WSM_Fallback_User__c = users[1].Id;
        update grp;
        WSM_Round_Robin_Member__c onlyMember = WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);
        onlyMember.WSM_Active__c = false;
        update onlyMember;

        WSM_RRResult result = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        System.assertEquals(WSM_RRResult.STATUS_FALLBACK, result.status);
        System.assertEquals(users[1].Id, result.userId);
        System.assertEquals(null, result.memberId);
        WSM_Assignment_Log__c log = [SELECT WSM_Status__c, WSM_Detail__c FROM WSM_Assignment_Log__c WHERE Id = :result.logId];
        System.assertEquals('Fallback', log.WSM_Status__c);
        System.assert(log.WSM_Detail__c.contains('inactive'), 'The skip summary should explain why the pool was empty.');
    }

    @isTest
    static void noEligibleMembers_whenNoFallbackConfigured() {
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('No Fallback Group', 'Strict Rotation');
        WSM_Round_Robin_Member__c onlyMember = WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);
        onlyMember.WSM_Active__c = false;
        update onlyMember;

        WSM_RRResult result = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        System.assertEquals(WSM_RRResult.STATUS_NO_ELIGIBLE_MEMBERS, result.status);
        System.assertEquals(false, result.isSuccess);
    }

    @isTest
    static void unknownAlgorithm_engineDefaultsToStrictAndLogsWarning() {
        // WSM_Algorithm__c is a restricted picklist, so a bad value can never actually be
        // persisted via DML (allOrNone=false would just silently drop the field change,
        // not bypass the restriction), a stub selector hands the engine an in-memory
        // group row carrying an unrecognized value instead, simulating data drift from a
        // future release landing on an org still running this version.
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Weird Algorithm', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        WSM_RoundRobinEngine engine = new WSM_RoundRobinEngine();
        engine.selector = new BadAlgorithmSelector();

        WSM_RRResult result = engine.assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status, 'An unrecognized algorithm must still resolve to Strict Rotation and succeed.');
        WSM_Assignment_Log__c log = [SELECT WSM_Detail__c FROM WSM_Assignment_Log__c WHERE Id = :result.logId];
        System.assert(log.WSM_Detail__c != null && log.WSM_Detail__c.contains('Unknown algorithm'), 'The fallback must be recorded in the log detail.');
    }

    @isTest
    static void lockRetry_transientFailureSucceedsOnSecondAttempt() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Retry Group', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        WSM_RoundRobinEngine engine = new WSM_RoundRobinEngine();
        ThrowsOnceSelector stub = new ThrowsOnceSelector();
        engine.selector = stub;

        WSM_RRResult result = engine.assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status, 'A single transient lock failure must be absorbed by the one retry.');
        System.assertEquals(2, stub.lockAttempts);
    }

    @isTest
    static void lockTimeout_persistentFailureProducesLockTimeoutAndErrorLog() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Timeout Group', 'Strict Rotation');

        WSM_RoundRobinEngine engine = new WSM_RoundRobinEngine();
        AlwaysThrowsSelector stub = new AlwaysThrowsSelector();
        engine.selector = stub;

        WSM_RRResult result = engine.assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        System.assertEquals(WSM_RRResult.STATUS_LOCK_TIMEOUT, result.status);
        System.assertEquals(2, stub.lockAttempts, 'Exactly one retry (two total attempts) must be made before giving up.');
        List<WSM_Assignment_Log__c> errorLogs = [SELECT Id FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id AND WSM_Status__c = 'Error'];
        System.assertEquals(1, errorLogs.size(), 'A LOCK_TIMEOUT outcome must still produce an Error log row.');
    }

    @isTest
    static void preview_producesNoDmlAndOrderedVerdicts() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Preview Group', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_Round_Robin_Member__c eligibleMember = WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);
        WSM_Round_Robin_Member__c inactiveMember = WSM_RoundRobinTestFactory.makeMember(grp.Id, users[1].Id);
        inactiveMember.WSM_Active__c = false;
        insert inactiveMember;

        Integer logCountBefore = [SELECT COUNT() FROM WSM_Assignment_Log__c];
        Integer dmlBefore = Limits.getDmlStatements();

        WSM_RRPreview preview = new WSM_RoundRobinEngine().preview(grp.Id);

        System.assertEquals(dmlBefore, Limits.getDmlStatements(), 'preview() must never issue DML.');
        System.assertEquals(logCountBefore, [SELECT COUNT() FROM WSM_Assignment_Log__c], 'preview() must never write a log row.');
        System.assertEquals(eligibleMember.Id, preview.wouldAssignMemberId);
        System.assertEquals(users[0].Id, preview.wouldAssignUserId);
        System.assertEquals(2, preview.verdicts.size());
        for (WSM_RRPreview.MemberVerdict v : preview.verdicts) {
            if (v.memberId == eligibleMember.Id) {
                System.assertEquals(true, v.eligible);
                System.assertEquals(1, v.sortRank);
            } else {
                System.assertEquals(false, v.eligible);
                System.assertEquals('Inactive', v.skipReason);
                System.assertEquals(null, v.sortRank);
            }
        }
    }

    @isTest
    static void assign_isolatesOneBadRequestFromRestOfBatch() {
        WSM_Round_Robin_Group__c goodGroup = WSM_RoundRobinTestFactory.insertGroup('Good Group', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(goodGroup.Id, users[0].Id);

        // A request with neither groupId nor groupDeveloperName resolves to
        // GROUP_NOT_FOUND at the resolve step, the well-formed request alongside it in
        // the same batch must still succeed.
        List<WSM_RRRequest> requests = new List<WSM_RRRequest>{ new WSM_RRRequest(), new WSM_RRRequest(goodGroup.Id) };
        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(requests);

        System.assertEquals(WSM_RRResult.STATUS_GROUP_NOT_FOUND, results[0].status);
        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, results[1].status);
    }

    @isTest
    static void withoutSharingEngine_worksForRestrictedUser() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Smoke Test Group', 'Strict Rotation');
        List<User> poolUsers = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, poolUsers[0].Id);
        User restrictedUser = WSM_RoundRobinTestFactory.insertRestrictedUser();

        System.runAs(restrictedUser) {
            WSM_RRResult result = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
            System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status,
                'The without-sharing engine must still work end-to-end for a non-admin running user.');
        }
    }

    private class ThrowsOnceSelector extends WSM_RoundRobinSelector {
        Integer lockAttempts = 0;
        public override List<WSM_Round_Robin_Group__c> lockGroups(Set<Id> groupIds) {
            lockAttempts++;
            if (lockAttempts == 1) {
                throw new QueryException('UNABLE_TO_LOCK_ROW: simulated contention');
            }
            return super.lockGroups(groupIds);
        }
    }

    private class AlwaysThrowsSelector extends WSM_RoundRobinSelector {
        Integer lockAttempts = 0;
        public override List<WSM_Round_Robin_Group__c> lockGroups(Set<Id> groupIds) {
            lockAttempts++;
            throw new QueryException('UNABLE_TO_LOCK_ROW: simulated permanent contention');
        }
    }

    private class BadAlgorithmSelector extends WSM_RoundRobinSelector {
        public override List<WSM_Round_Robin_Group__c> lockGroups(Set<Id> groupIds) {
            List<WSM_Round_Robin_Group__c> groups = super.lockGroups(groupIds);
            for (WSM_Round_Robin_Group__c g : groups) {
                g.WSM_Algorithm__c = 'Some Future Algorithm';
            }
            return groups;
        }
    }

    @isTest
    static void fallbackQueue_usedWhenNoUserFallbackAndPoolEmpty() {
        Group queue = new Group(Name = 'RR Test Queue', DeveloperName = 'RR_Test_Queue', Type = 'Queue');
        insert queue;
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.makeGroup('Queue Fallback Group', 'Strict Rotation');
        grp.WSM_Fallback_Queue_Id__c = queue.Id;
        insert grp;
        WSM_Round_Robin_Member__c paused = WSM_RoundRobinTestFactory.makeMember(grp.Id, UserInfo.getUserId());
        paused.WSM_Active__c = false;
        insert paused;

        WSM_RRResult result = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        System.assertEquals(WSM_RRResult.STATUS_FALLBACK, result.status, 'Empty pool with a queue fallback must return FALLBACK.');
        System.assertEquals(null, result.userId, 'Queue fallback must not populate userId.');
        System.assertEquals(queue.Id, result.queueId, 'Queue fallback must return the queue Id.');
        System.assertEquals(queue.Id, result.ownerId, 'ownerId must surface the queue when no user was assigned.');
        WSM_Assignment_Log__c log = [SELECT WSM_Status__c, WSM_Detail__c FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id LIMIT 1];
        System.assertEquals('Fallback', log.WSM_Status__c);
        System.assert(log.WSM_Detail__c.contains(queue.Id), 'Log detail must record the fallback queue Id.');
    }

    @isTest
    static void fallbackUser_winsOverFallbackQueue() {
        Group queue = new Group(Name = 'RR Loser Queue', DeveloperName = 'RR_Loser_Queue', Type = 'Queue');
        insert queue;
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.makeGroup('Both Fallbacks Group', 'Strict Rotation');
        grp.WSM_Fallback_User__c = UserInfo.getUserId();
        grp.WSM_Fallback_Queue_Id__c = queue.Id;
        insert grp;

        WSM_RRResult result = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        System.assertEquals(WSM_RRResult.STATUS_FALLBACK, result.status);
        System.assertEquals(UserInfo.getUserId(), result.userId, 'Fallback user takes precedence over the queue.');
        System.assertEquals(null, result.queueId);
    }
}
