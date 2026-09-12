/**
 * End-to-end coverage for Capacity Queries inside the engine: real Accounts counted by a
 * real aggregate, caps that actually block, Least Loaded ranking off org data, the tier
 * walk, bulk levelling within one transaction, and a cap whose value comes off the record
 * being routed.
 *
 * These tests count Accounts because Account and its Name/Industry/OwnerId fields exist in
 * every org, so the suite does not depend on any customisation. WSM_CapacityQuery_Test
 * covers the compiler and the injection surface with no DML at all.
 */
@isTest
private class WSM_CapacityEngine_Test {

    private static final String MARKER = 'WSM RR Capacity Test';

    /** Accounts owned by the given user, matching the capacity query's filter. */
    private static void makeCountableAccounts(Id ownerId, Integer count, String industry) {
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(new Account(
                Name = MARKER + ' ' + i,
                Industry = industry,
                OwnerId = ownerId
            ));
        }
        insert accounts;
    }

    private static WSM_Capacity_Query__c capacityQuery(Id groupId, String label, String role, Integer cap) {
        WSM_Capacity_Query__c config = WSM_RoundRobinTestFactory.makeCapacityQuery(groupId, label, 'Account', role, cap);
        insert config;
        insert WSM_RoundRobinTestFactory.makeFilter(config.Id, 1, 'Name', 'starts with',
            WSM_CapacityQueryBuilder.SRC_LITERAL, MARKER);
        return config;
    }

    // ---------------------------------------------------------------- caps

    @isTest
    static void capBlocksTheMemberWhoIsOverIt() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Cap Group', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });

        // users[0] is over a cap of 2, users[1] has nothing.
        makeCountableAccounts(users[0].Id, 3, 'Banking');
        capacityQuery(grp.Id, 'Open Accounts', WSM_CapacityQueryDef.ROLE_CAP, 2);

        Test.startTest();
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status, 'The uncapped member should have taken it.');
        System.assertEquals(users[1].Id, result.userId,
            'The member sitting on 3 counted Accounts against a cap of 2 must be skipped, even though Sort Order puts them first.');

        WSM_Assignment_Log__c log = [SELECT WSM_Detail__c FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id LIMIT 1];
        System.assertEquals(null, log.WSM_Detail__c,
            'A clean assignment must not carry warnings; the skip only shows up when nobody is left.');
    }

    @isTest
    static void everyoneOverTheCapFallsBackAndSaysWhy() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('All Capped', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        makeCountableAccounts(users[0].Id, 2, 'Banking');
        makeCountableAccounts(users[1].Id, 2, 'Banking');
        capacityQuery(grp.Id, 'Open Accounts', WSM_CapacityQueryDef.ROLE_CAP, 1);

        Test.startTest();
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(WSM_RRResult.STATUS_NO_ELIGIBLE_MEMBERS, result.status,
            'With everyone over the cap and no fallback configured, the outcome must say so rather than assigning anyway.');

        WSM_Assignment_Log__c log = [SELECT WSM_Detail__c, WSM_Status__c FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id LIMIT 1];
        System.assertEquals('No Eligible Members', log.WSM_Status__c, 'The log must record the real outcome.');
        System.assert(log.WSM_Detail__c.contains('at cap'),
            'The detail must explain that the cap was the reason, not just that nobody was available: ' + log.WSM_Detail__c);
    }

    // ---------------------------------------------------------------- Least Loaded

    @isTest
    static void leastLoadedRanksOffRealOrgData() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Loaded Group', WSM_StrategyFactory.LEAST_LOADED);
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        // Sort Order 0 is the busy one, so a win for users[1] can only come from the load metric.
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        makeCountableAccounts(users[0].Id, 4, 'Banking');
        makeCountableAccounts(users[1].Id, 1, 'Banking');
        capacityQuery(grp.Id, 'Book Size', WSM_CapacityQueryDef.ROLE_LOAD, null);

        Test.startTest();
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(users[1].Id, result.userId,
            'Least Loaded must pick the member with 1 counted Account over the one with 4, regardless of Sort Order.');
    }

    @isTest
    static void bulkLevelsWithinOneTransaction() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Bulk Load', WSM_StrategyFactory.LEAST_LOADED);
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        makeCountableAccounts(users[0].Id, 5, 'Banking');
        makeCountableAccounts(users[1].Id, 5, 'Banking');
        capacityQuery(grp.Id, 'Book Size', WSM_CapacityQueryDef.ROLE_LOAD, null);

        List<WSM_RRRequest> requests = new List<WSM_RRRequest>();
        for (Integer i = 0; i < 10; i++) {
            requests.add(new WSM_RRRequest(grp.Id));
        }

        Test.startTest();
        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(requests);
        Test.stopTest();

        Map<Id, Integer> countByUser = new Map<Id, Integer>();
        for (WSM_RRResult r : results) {
            System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, r.status, 'Every request in the batch must be assigned.');
            Integer running = countByUser.containsKey(r.userId) ? countByUser.get(r.userId) : 0;
            countByUser.put(r.userId, running + 1);
        }
        System.assertEquals(2, countByUser.size(),
            'Both members must receive work. If the pick were not charged against the load metric in-memory, all 10 would have gone to whoever was cheapest when the batch started, because the new records do not exist until commit.');
        System.assertEquals(5, countByUser.get(users[0].Id), 'Ten requests across two equally loaded members must split evenly.');
        System.assertEquals(5, countByUser.get(users[1].Id), 'Ten requests across two equally loaded members must split evenly.');
    }

    @isTest
    static void weightBuysAShareOfRealLoad() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Weighted Load', WSM_StrategyFactory.LEAST_LOADED);
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        List<WSM_Round_Robin_Member__c> members =
            WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        members[0].WSM_Weight__c = 3;
        members[1].WSM_Weight__c = 1;
        update members;
        capacityQuery(grp.Id, 'Book Size', WSM_CapacityQueryDef.ROLE_LOAD, null);

        List<WSM_RRRequest> requests = new List<WSM_RRRequest>();
        for (Integer i = 0; i < 12; i++) {
            requests.add(new WSM_RRRequest(grp.Id));
        }

        Test.startTest();
        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(requests);
        Test.stopTest();

        Map<Id, Integer> countByUser = new Map<Id, Integer>();
        for (WSM_RRResult r : results) {
            Integer running = countByUser.containsKey(r.userId) ? countByUser.get(r.userId) : 0;
            countByUser.put(r.userId, running + 1);
        }
        System.assertEquals(9, countByUser.get(users[0].Id),
            'Weight 3 against weight 1 must take three of every four, which is 9 of 12.');
        System.assertEquals(3, countByUser.get(users[1].Id),
            'The weight-1 member takes one of every four, which is the "only every third lead" case.');
    }

    // ---------------------------------------------------------------- tiers

    @isTest
    static void tierTwoIsOnlyUsedWhenTierOneIsUnavailable() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Tiered', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        List<WSM_Round_Robin_Member__c> members =
            WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        members[0].WSM_Tier__c = 1;
        members[1].WSM_Tier__c = 2;
        update members;
        capacityQuery(grp.Id, 'Open Accounts', WSM_CapacityQueryDef.ROLE_CAP, 2);

        Test.startTest();
        // Tier 1 is free, so the bench must not be touched.
        WSM_RRResult first = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];

        // Now push tier 1 over the cap and ask again.
        makeCountableAccounts(users[0].Id, 2, 'Banking');
        WSM_RRResult second = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(users[0].Id, first.userId, 'While tier 1 is available the tier 2 bench must never be used.');
        System.assertEquals(users[1].Id, second.userId, 'With tier 1 over its cap, the work must fall to tier 2.');

        List<WSM_Assignment_Log__c> logs = [
            SELECT WSM_Detail__c, WSM_Assigned_User__c FROM WSM_Assignment_Log__c
            WHERE WSM_Group__c = :grp.Id AND WSM_Assigned_User__c = :users[1].Id];
        System.assertEquals(1, logs.size(), 'The tier 2 assignment must be logged.');
        System.assert(logs[0].WSM_Detail__c.contains('tier 2'),
            'The log must say the work was filled from a later tier, so an admin can see the bench is being used: ' + logs[0].WSM_Detail__c);
    }

    @isTest
    static void capsStillApplyOnTheOverflowTier() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Tiered Capped', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        List<WSM_Round_Robin_Member__c> members =
            WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        members[0].WSM_Tier__c = 1;
        members[1].WSM_Tier__c = 2;
        update members;
        makeCountableAccounts(users[0].Id, 2, 'Banking');
        makeCountableAccounts(users[1].Id, 2, 'Banking');
        capacityQuery(grp.Id, 'Open Accounts', WSM_CapacityQueryDef.ROLE_CAP, 1);

        Test.startTest();
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(WSM_RRResult.STATUS_NO_ELIGIBLE_MEMBERS, result.status,
            'An overflow tier is a bench, not an escape hatch: a member on tier 2 who is over the cap must still be skipped. This is exactly the defect that made SFP route every lead to one person.');
    }

    // ---------------------------------------------------------------- routed record value

    @isTest
    static void capCanDependOnTheRecordBeingRouted() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Routed', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });

        // users[0] already holds 2 Banking accounts and 0 Energy ones.
        makeCountableAccounts(users[0].Id, 2, 'Banking');

        WSM_Capacity_Query__c config = WSM_RoundRobinTestFactory.makeCapacityQuery(
            grp.Id, 'Same Industry', 'Account', WSM_CapacityQueryDef.ROLE_CAP, 2);
        insert config;
        WSM_Capacity_Filter__c matchIndustry = WSM_RoundRobinTestFactory.makeFilter(
            config.Id, 1, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_ROUTED_FIELD, null);
        matchIndustry.WSM_Routed_Record_Field__c = 'Industry';
        insert matchIndustry;

        Account bankingLead = new Account(Name = MARKER + ' routed banking', Industry = 'Banking');
        Account energyLead = new Account(Name = MARKER + ' routed energy', Industry = 'Energy');
        insert new List<Account>{ bankingLead, energyLead };

        Test.startTest();
        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{
            new WSM_RRRequest(grp.Id, bankingLead.Id, 'banking'),
            new WSM_RRRequest(grp.Id, energyLead.Id, 'energy')
        });
        Test.stopTest();

        // Assert the log is clean FIRST. A capacity query that fails at runtime degrades to
        // "unevaluated" and stops capping anyone, so without this the assertions below
        // could pass or fail for reasons that have nothing to do with the routing logic.
        for (WSM_Assignment_Log__c log : [SELECT WSM_Detail__c FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id]) {
            System.assertEquals(null, log.WSM_Detail__c,
                'The capacity query must have actually run. A warning here means it silently degraded and capped nobody: ' + log.WSM_Detail__c);
        }

        System.assertEquals(users[1].Id, results[0].userId,
            'Routing a Banking record must skip the member already holding 2 Banking accounts against a cap of 2.');
        System.assertEquals(users[0].Id, results[1].userId,
            'Routing an Energy record must be free to use that same member, because the cap is counted per the routed record\'s own industry.');
    }

    @isTest
    static void missingRoutedValueWarnsAndStillRoutes() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Routed Missing', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        WSM_Capacity_Query__c config = WSM_RoundRobinTestFactory.makeCapacityQuery(
            grp.Id, 'Same Industry', 'Account', WSM_CapacityQueryDef.ROLE_CAP, 1);
        insert config;
        WSM_Capacity_Filter__c matchIndustry = WSM_RoundRobinTestFactory.makeFilter(
            config.Id, 1, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_ROUTED_FIELD, null);
        matchIndustry.WSM_Routed_Record_Field__c = 'Industry';
        insert matchIndustry;

        Test.startTest();
        // No Assigned Record Id at all, so the capacity query has no value to work from.
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status,
            'A missing input for one capacity query must not stop routing; blocking everyone would be worse than routing and reporting it.');
        WSM_Assignment_Log__c log = [SELECT WSM_Detail__c FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id LIMIT 1];
        System.assert(log.WSM_Detail__c != null && log.WSM_Detail__c.contains('was not applied'),
            'The log must say which capacity query was skipped and why: ' + log.WSM_Detail__c);
    }

    // ---------------------------------------------------------------- degradation

    @isTest
    static void brokenConfigWarnsButDoesNotStopRouting() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Broken Config', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        WSM_Capacity_Query__c config = WSM_RoundRobinTestFactory.makeCapacityQuery(
            grp.Id, 'Typo Query', 'Acccount', WSM_CapacityQueryDef.ROLE_CAP, 1);
        insert config;
        insert WSM_RoundRobinTestFactory.makeFilter(config.Id, 1, 'Name', 'equals',
            WSM_CapacityQueryBuilder.SRC_LITERAL, 'x');

        Test.startTest();
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status,
            'A misspelled object name must degrade to a warning, not take routing down for the whole group.');
        WSM_Assignment_Log__c log = [SELECT WSM_Detail__c FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id LIMIT 1];
        System.assert(log.WSM_Detail__c.contains('Typo Query'),
            'The warning must name the offending capacity query so it can be found and fixed: ' + log.WSM_Detail__c);
    }

    @isTest
    static void leastLoadedWithNoLoadMetricDegradesAndSaysSo() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('No Metric', WSM_StrategyFactory.LEAST_LOADED);
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        Test.startTest();
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status, 'Routing must still happen.');
        WSM_Assignment_Log__c log = [SELECT WSM_Detail__c FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id LIMIT 1];
        System.assert(log.WSM_Detail__c.contains('Least Loaded'),
            'Choosing Least Loaded with nothing to rank on must be called out on the log: ' + log.WSM_Detail__c);
    }

    @isTest
    static void tooManyCapacityQueriesIsCappedAndWarned() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Too Many', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        for (Integer i = 0; i < 7; i++) {
            capacityQuery(grp.Id, 'Count ' + i, WSM_CapacityQueryDef.ROLE_CAP, 99);
        }

        Test.startTest();
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, result.status, 'Routing must survive an over-configured group.');
        WSM_Assignment_Log__c log = [SELECT WSM_Detail__c FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id LIMIT 1];
        System.assert(log.WSM_Detail__c.contains('were not evaluated'),
            'Going past the per-group ceiling must be reported, not silently truncated: ' + log.WSM_Detail__c);
    }

    // ---------------------------------------------------------------- query footprint

    @isTest
    static void footprintDoesNotGrowWithPoolSizeOrBatchSize() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Footprint', WSM_StrategyFactory.LEAST_LOADED);
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(5);
        List<Id> userIds = new List<Id>();
        for (User u : users) {
            userIds.add(u.Id);
        }
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, userIds);
        capacityQuery(grp.Id, 'Book Size', WSM_CapacityQueryDef.ROLE_LOAD, null);
        capacityQuery(grp.Id, 'Second Count', WSM_CapacityQueryDef.ROLE_CAP, 99);

        List<WSM_RRRequest> requests = new List<WSM_RRRequest>();
        for (Integer i = 0; i < 50; i++) {
            requests.add(new WSM_RRRequest(grp.Id));
        }

        // Deliberately not wrapped in startTest/stopTest: those reset the governor
        // counters, which would make a before/after delta across the boundary meaningless.
        Integer queriesBefore = Limits.getQueries();
        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(requests);
        Integer used = Limits.getQueries() - queriesBefore;

        System.assertEquals(50, results.size(), 'Every request must come back.');
        System.assert(used <= 8, '50 requests across a 5-member pool with 2 capacity queries must stay on a flat '
            + 'footprint (lock + members + period + config + 2 aggregates), not scale with either. Used: ' + used);
    }

    // ---------------------------------------------------------------- preview

    @isTest
    static void previewShowsCapacityReadingsAndTiers() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Preview', WSM_StrategyFactory.LEAST_LOADED);
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        List<WSM_Round_Robin_Member__c> members =
            WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        members[1].WSM_Tier__c = 2;
        update members;
        makeCountableAccounts(users[0].Id, 3, 'Banking');
        capacityQuery(grp.Id, 'Book Size', WSM_CapacityQueryDef.ROLE_BOTH, 10);

        Test.startTest();
        WSM_RRPreview preview = new WSM_RoundRobinEngine().preview(grp.Id);
        Test.stopTest();

        System.assertEquals(2, preview.verdicts.size(), 'Every member must get a verdict.');
        System.assertEquals(1, preview.assignedFromTier, 'Tier 1 is available, so the pick must come from there.');

        for (WSM_RRPreview.MemberVerdict verdict : preview.verdicts) {
            System.assertEquals(1, verdict.capacity.size(), 'The single capacity query must produce one reading per member.');
            WSM_RRPreview.CapacityReading reading = verdict.capacity[0];
            System.assertEquals('Book Size', reading.label, 'The reading must be labelled for the admin.');
            System.assertEquals(true, reading.isCap, 'The combined role is a cap.');
            System.assertEquals(true, reading.isLoadMetric, 'The combined role is also a load metric.');
            if (verdict.userId == users[0].Id) {
                System.assertEquals(3, reading.count, 'The busy member\'s reading must show their real count.');
                System.assertEquals(1, verdict.tier, 'That member is on tier 1.');
                System.assertEquals(true, verdict.tierReached, 'Tier 1 was evaluated.');
                System.assertEquals(3, verdict.externalLoad, 'The load must be exposed so the simulator can explain the ranking.');
            } else {
                System.assertEquals(2, verdict.tier, 'The bench member is on tier 2.');
                System.assertEquals(false, verdict.tierReached,
                    'Tier 2 was never evaluated, so the honest answer is "not needed" rather than a rank or a skip reason.');
            }
        }
    }

    @isTest
    static void previewFlagsAReadingItCannotTake() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Preview Routed', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);

        WSM_Capacity_Query__c config = WSM_RoundRobinTestFactory.makeCapacityQuery(
            grp.Id, 'Same Industry', 'Account', WSM_CapacityQueryDef.ROLE_CAP, 1);
        insert config;
        WSM_Capacity_Filter__c matchIndustry = WSM_RoundRobinTestFactory.makeFilter(
            config.Id, 1, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_ROUTED_FIELD, null);
        matchIndustry.WSM_Routed_Record_Field__c = 'Industry';
        insert matchIndustry;

        Test.startTest();
        WSM_RRPreview preview = new WSM_RoundRobinEngine().preview(grp.Id);
        Test.stopTest();

        WSM_RRPreview.CapacityReading reading = preview.verdicts[0].capacity[0];
        System.assertEquals(null, reading.count,
            'A reading that needs a routed record must come back empty rather than showing a misleading zero.');
        System.assertNotEquals(null, reading.unavailableReason, 'And it must explain why it is empty.');
    }

    @isTest
    static void previewSurfacesBrokenConfig() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Preview Broken', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(1);
        WSM_RoundRobinTestFactory.insertMember(grp.Id, users[0].Id);
        WSM_Capacity_Query__c config = WSM_RoundRobinTestFactory.makeCapacityQuery(
            grp.Id, 'Bad Field', 'Account', WSM_CapacityQueryDef.ROLE_CAP, 1);
        insert config;
        insert WSM_RoundRobinTestFactory.makeFilter(config.Id, 1, 'NopeNotAField__c', 'equals',
            WSM_CapacityQueryBuilder.SRC_LITERAL, 'x');

        Test.startTest();
        WSM_RRPreview preview = new WSM_RoundRobinEngine().preview(grp.Id);
        Test.stopTest();

        System.assertEquals(1, preview.warnings.size(), 'The simulator is where an admin should find out their config is broken.');
        System.assert(preview.warnings[0].contains('Bad Field'), 'The warning must name the capacity query: ' + preview.warnings[0]);
        System.assertEquals(0, preview.verdicts[0].capacity.size(),
            'A definition that will not compile must not pretend to have a reading.');
    }

    // ---------------------------------------------------------------- exception path

    @isTest
    static void unparseableBooleanIsRejectedByTheCompiler() {
        WSM_Capacity_Query__c config = new WSM_Capacity_Query__c(
            Id = WSM_RoundRobinTestFactory.fakeCapacityQueryId(901),
            WSM_Label__c = 'Bad Boolean',
            WSM_Object__c = 'Account',
            WSM_Role__c = WSM_CapacityQueryDef.ROLE_CAP,
            WSM_Cap__c = 1
        );
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(config,
            new List<WSM_Capacity_Filter__c>{
                WSM_RoundRobinTestFactory.makeFilter(null, 1, 'IsDeleted', 'equals',
                    WSM_CapacityQueryBuilder.SRC_LITERAL, 'sort-of')
            });

        System.assertEquals(false, def.isValid,
            'A checkbox field only accepts true or false; anything else must be caught at compile time.');
    }

    @isTest
    static void tooManyInValuesIsRejected() {
        List<String> many = new List<String>();
        for (Integer i = 0; i < 120; i++) {
            many.add('v' + i);
        }
        WSM_Capacity_Query__c config = new WSM_Capacity_Query__c(
            Id = WSM_RoundRobinTestFactory.fakeCapacityQueryId(902),
            WSM_Label__c = 'Huge IN',
            WSM_Object__c = 'Account',
            WSM_Role__c = WSM_CapacityQueryDef.ROLE_CAP,
            WSM_Cap__c = 1
        );
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(config,
            new List<WSM_Capacity_Filter__c>{
                WSM_RoundRobinTestFactory.makeFilter(null, 1, 'Industry', 'in',
                    WSM_CapacityQueryBuilder.SRC_LITERAL, String.join(many, ','))
            });

        System.assertEquals(false, def.isValid, 'An unbounded IN list must be rejected rather than built into a query.');
    }

    // ---------------------------------------------------------------- floor

    /** A capacity query that is a Load Metric with a floor, counting the SMOKE CAP accounts. */
    private static WSM_Capacity_Query__c floorQuery(Id groupId, Integer floor, Integer cap) {
        WSM_Capacity_Query__c config = WSM_RoundRobinTestFactory.makeCapacityQuery(
            groupId, 'Book Size', 'Account',
            cap == null ? WSM_CapacityQueryDef.ROLE_LOAD : WSM_CapacityQueryDef.ROLE_BOTH, cap);
        config.WSM_Floor__c = floor;
        insert config;
        insert WSM_RoundRobinTestFactory.makeFilter(config.Id, 1, 'Name', 'starts with',
            WSM_CapacityQueryBuilder.SRC_LITERAL, MARKER);
        return config;
    }

    @isTest
    static void floorServesTheUnderServedFirstEvenWhenTheyAreNotTheLeastLoaded() {
        // Strict Rotation deliberately, so the ONLY thing that can put the under-floor
        // member first is the floor band, not a load comparison.
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Floor First', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        // users[0] sorts first and is comfortably above the floor; users[1] is under it.
        makeCountableAccounts(users[0].Id, 6, 'Banking');
        makeCountableAccounts(users[1].Id, 1, 'Banking');
        floorQuery(grp.Id, 5, null);

        Test.startTest();
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(users[1].Id, result.userId,
            'The member under the floor must be served first, ahead of the one at Sort Order 0 who is already above it. This is the behaviour the old SFP flow intended and implemented backwards.');
        WSM_Assignment_Log__c log = [SELECT WSM_Detail__c FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id LIMIT 1];
        System.assert(log.WSM_Detail__c != null && log.WSM_Detail__c.contains('floor band'),
            'The log must say the pick came out of the floor band: ' + log.WSM_Detail__c);
    }

    @isTest
    static void floorIsAPriorityBandNotAGate() {
        // Everyone under the floor: the band equals the pool, so it must be a no-op and
        // normal ordering decides. A floor must never block anybody.
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Floor NoOp', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        floorQuery(grp.Id, 5, null);

        Test.startTest();
        List<WSM_RRResult> results = new WSM_RoundRobinEngine().assign(new List<WSM_RRRequest>{
            new WSM_RRRequest(grp.Id), new WSM_RRRequest(grp.Id) });
        Test.stopTest();

        System.assertEquals(WSM_RRResult.STATUS_ASSIGNED, results[0].status, 'Nobody may be blocked by a floor.');
        System.assertEquals(users[0].Id, results[0].userId, 'With everyone under the floor, normal Sort Order decides.');
        System.assertEquals(users[1].Id, results[1].userId, 'And the rotation still alternates normally.');
    }

    @isTest
    static void floorStopsApplyingOnceTheMemberReachesIt() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Floor Reached', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        makeCountableAccounts(users[0].Id, 4, 'Banking');
        makeCountableAccounts(users[1].Id, 4, 'Banking');
        floorQuery(grp.Id, 3, null);

        Test.startTest();
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(users[0].Id, result.userId,
            'With both members at or above the floor, the floor is inert and Sort Order decides.');
        WSM_Assignment_Log__c log = [SELECT WSM_Detail__c FROM WSM_Assignment_Log__c WHERE WSM_Group__c = :grp.Id LIMIT 1];
        System.assertEquals(null, log.WSM_Detail__c, 'An inert floor must not add noise to the log.');
    }

    @isTest
    static void floorAppliesInsideATierNotAcrossTiers() {
        // A tier 2 member under the floor must NOT be pulled ahead of an available tier 1
        // member. Tiers are the harder boundary; the floor only reorders within one.
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Floor Tier', 'Strict Rotation');
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        List<WSM_Round_Robin_Member__c> members =
            WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        members[1].WSM_Tier__c = 2;
        update members;
        makeCountableAccounts(users[0].Id, 9, 'Banking');
        floorQuery(grp.Id, 5, null);

        Test.startTest();
        WSM_RRResult result = new WSM_RoundRobinEngine().assign(
            new List<WSM_RRRequest>{ new WSM_RRRequest(grp.Id) })[0];
        Test.stopTest();

        System.assertEquals(users[0].Id, result.userId,
            'The tier 1 member wins even though the tier 2 member is under the floor. A bench is a bench; the floor cannot promote across a tier boundary.');
    }

    @isTest
    static void floorMustBeLowerThanCap() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Floor Bad', 'Strict Rotation');
        WSM_Capacity_Query__c config = floorQuery(grp.Id, 10, 5);

        List<WSM_RR_AdminController.CapacityQueryRow> rows = WSM_RR_AdminController.getCapacityQueries(grp.Id);

        System.assertEquals(false, rows[0].valid,
            'A floor at or above the cap would mark a member as both priority and blocked, which is incoherent.');
        System.assert(rows[0].invalidReason.contains('must be lower than Cap'),
            'The reason must explain the contradiction: ' + rows[0].invalidReason);
    }

    @isTest
    static void previewReportsFloorStatus() {
        WSM_Round_Robin_Group__c grp = WSM_RoundRobinTestFactory.insertGroup('Floor Preview', WSM_StrategyFactory.LEAST_LOADED);
        List<User> users = WSM_RoundRobinTestFactory.insertUsers(2);
        WSM_RoundRobinTestFactory.insertMembers(grp.Id, new List<Id>{ users[0].Id, users[1].Id });
        makeCountableAccounts(users[0].Id, 8, 'Banking');
        makeCountableAccounts(users[1].Id, 2, 'Banking');
        floorQuery(grp.Id, 5, null);

        Test.startTest();
        WSM_RRPreview preview = new WSM_RoundRobinEngine().preview(grp.Id);
        Test.stopTest();

        for (WSM_RRPreview.MemberVerdict v : preview.verdicts) {
            WSM_RRPreview.CapacityReading reading = v.capacity[0];
            System.assertEquals(5, reading.floor, 'The floor must be exposed so the simulator can explain the ordering.');
            if (v.userId == users[1].Id) {
                System.assertEquals(true, reading.belowFloor, 'The member on 2 is under a floor of 5.');
                System.assertEquals(1, v.sortRank, 'And must therefore rank first.');
            } else {
                System.assertEquals(false, reading.belowFloor, 'The member on 8 is above a floor of 5.');
            }
        }
    }
}
