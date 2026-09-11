/**
 * Compiler, injection and ranking tests for Capacity Queries. Everything here is
 * in-memory: unsaved config records with synthetic Ids, no DML and no org configuration,
 * so it runs identically in a scratch org and in a subscriber org. Engine integration
 * against real records lives in WSM_RoundRobinEngine_Test.
 *
 * Real assertions throughout. The whole value of this feature rests on the compiler
 * refusing bad input, so "it ran without throwing" would prove nothing.
 */
@isTest
private class WSM_CapacityQuery_Test {

    private static Integer seq = 0;

    private static WSM_Capacity_Query__c config(String objectName, String role, Integer cap) {
        seq++;
        return new WSM_Capacity_Query__c(
            Id = WSM_RoundRobinTestFactory.fakeCapacityQueryId(seq),
            WSM_Label__c = 'Test Count ' + seq,
            WSM_Object__c = objectName,
            WSM_Role__c = role,
            WSM_Cap__c = cap,
            WSM_Active__c = true
        );
    }

    private static WSM_Capacity_Filter__c filter(Integer filterNumber, String fieldName, String operator,
            String valueSource, String value) {
        return new WSM_Capacity_Filter__c(
            WSM_Filter_Number__c = filterNumber,
            WSM_Field__c = fieldName,
            WSM_Operator__c = operator,
            WSM_Value_Source__c = valueSource,
            WSM_Value__c = value
        );
    }

    private static List<WSM_Capacity_Filter__c> one(WSM_Capacity_Filter__c f) {
        return new List<WSM_Capacity_Filter__c>{ f };
    }

    // ---------------------------------------------------------------- happy path

    @isTest
    static void compile_validConfigResolvesAgainstSchema() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('account', WSM_CapacityQueryDef.ROLE_CAP, 20),
            one(filter(1, 'name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'Acme')));

        System.assertEquals(true, def.isValid, 'A well-formed config must compile. Reason given: ' + def.invalidReason);
        System.assertEquals('Account', def.objectName, 'The object name must come from the schema describe, not the admin\'s lowercase typing.');
        System.assertEquals('OwnerId', def.ownerFieldName, 'A blank Owner Field must default to OwnerId.');
        System.assertEquals(true, def.isCap, 'Role Cap must report isCap.');
        System.assertEquals(false, def.isLoadMetric, 'Role Cap alone must not report isLoadMetric.');
    }

    @isTest
    static void toSoql_isAlwaysACountGroupedByOwner() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 20),
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'Acme')));

        String soql = WSM_CapacityQueryBuilder.toSoql(def, false);

        System.assert(soql.contains('COUNT(Id) cnt'), 'The aggregate must select COUNT(Id): ' + soql);
        System.assert(soql.contains('GROUP BY OwnerId'), 'The aggregate must group by the owner field: ' + soql);
        System.assert(soql.contains('OwnerId IN :ownerIds'), 'The aggregate must restrict to the pool: ' + soql);
        System.assert(soql.contains('Name = :b1'), 'The filter value must be a bind, not inlined: ' + soql);
        System.assert(!soql.containsIgnoreCase('Acme'), 'No admin-supplied value may appear in the query text: ' + soql);
    }

    @isTest
    static void binds_carryTheTypedValues() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 20),
            one(filter(1, 'NumberOfEmployees', 'greater than', WSM_CapacityQueryBuilder.SRC_LITERAL, '50')));

        System.assertEquals(true, def.isValid, 'Numeric comparison should compile. Reason: ' + def.invalidReason);
        Map<String, Object> bindMap = WSM_CapacityQueryBuilder.binds(def, new Set<Id>{ UserInfo.getUserId() }, null);

        System.assertEquals(50, bindMap.get('b1'), 'A numeric field\'s value must be bound as a number, not a string.');
        System.assertEquals(1, ((List<Id>) bindMap.get('ownerIds')).size(), 'The owner bind must carry the pool.');
    }

    @isTest
    static void likeWildcardsGoInTheBindNotTheQuery() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 5),
            one(filter(1, 'Name', 'contains', WSM_CapacityQueryBuilder.SRC_LITERAL, 'Acme')));

        String soql = WSM_CapacityQueryBuilder.toSoql(def, false);
        Map<String, Object> bindMap = WSM_CapacityQueryBuilder.binds(def, new Set<Id>{ UserInfo.getUserId() }, null);

        System.assert(soql.contains('Name LIKE :b1'), 'contains must compile to a bound LIKE: ' + soql);
        System.assertEquals('%Acme%', bindMap.get('b1'), 'The wildcards belong in the bound value.');
    }

    @isTest
    static void likeValueWildcardsAreEscapedSoTheyMatchLiterally() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 5),
            one(filter(1, 'Name', 'starts with', WSM_CapacityQueryBuilder.SRC_LITERAL, '100%_off')));

        Map<String, Object> bindMap = WSM_CapacityQueryBuilder.binds(def, new Set<Id>{ UserInfo.getUserId() }, null);

        System.assertEquals('100\\%\\_off%', bindMap.get('b1'),
            'A percent or underscore inside the admin\'s value must be escaped so it is matched literally rather than acting as a wildcard.');
    }

    @isTest
    static void filterLogicIsHonoured() {
        WSM_Capacity_Query__c cfg = config('Account', WSM_CapacityQueryDef.ROLE_CAP, 20);
        cfg.WSM_Filter_Logic__c = '1 AND (2 OR 3)';
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(cfg, new List<WSM_Capacity_Filter__c>{
            filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'Acme'),
            filter(2, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'Banking'),
            filter(3, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'Energy')
        });

        System.assertEquals(true, def.isValid, 'Valid logic must compile. Reason: ' + def.invalidReason);
        String soql = WSM_CapacityQueryBuilder.toSoql(def, false);
        System.assert(soql.contains('Name = :b1 AND ( Industry = :b2 OR Industry = :b3 )'),
            'Filter Logic must drive the predicate shape: ' + soql);
    }

    @isTest
    static void blankFilterLogicAndsEverything() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 20),
            new List<WSM_Capacity_Filter__c>{
                filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'Acme'),
                filter(2, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'Banking')
            });

        String soql = WSM_CapacityQueryBuilder.toSoql(def, false);
        System.assert(soql.contains('(Name = :b1 AND Industry = :b2)'),
            'With no Filter Logic every filter must be ANDed: ' + soql);
    }

    @isTest
    static void relativeDateLiteralIsInlinedOnlyWhenWhitelisted() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_LOAD, null),
            one(filter(1, 'CreatedDate', 'greater or equal', WSM_CapacityQueryBuilder.SRC_RELATIVE_DATE, 'LAST_N_DAYS:30')));

        System.assertEquals(true, def.isValid, 'A whitelisted date literal must compile. Reason: ' + def.invalidReason);
        String soql = WSM_CapacityQueryBuilder.toSoql(def, false);
        System.assert(soql.contains('CreatedDate >= LAST_N_DAYS:30'),
            'A date literal cannot be bound, so it must be inlined after whitelisting: ' + soql);
    }

    // ---------------------------------------------------------------- injection

    @isTest
    static void injection_objectNameIsRejected() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account WHERE Id != null OR Name LIKE \'%', WSM_CapacityQueryDef.ROLE_CAP, 1),
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'x')));

        System.assertEquals(false, def.isValid, 'An object name carrying SOQL must not resolve.');
        System.assertEquals(null, WSM_CapacityQueryBuilder.toSoql(def, false),
            'An invalid definition must never produce a query string.');
    }

    @isTest
    static void injection_fieldNameIsRejected() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1),
            one(filter(1, 'Name = \'x\' OR Id != null OR Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'y')));

        System.assertEquals(false, def.isValid, 'A field name carrying SOQL must not resolve.');
        System.assert(def.invalidReason.contains('does not exist'), 'The reason should name the unresolvable field: ' + def.invalidReason);
    }

    @isTest
    static void injection_ownerFieldIsRejected() {
        WSM_Capacity_Query__c cfg = config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1);
        cfg.WSM_Owner_Field__c = 'OwnerId, (SELECT Id FROM Contacts)';
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(cfg,
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'x')));

        System.assertEquals(false, def.isValid, 'An owner field carrying a subquery must not resolve.');
    }

    @isTest
    static void injection_filterLogicIsRejected() {
        WSM_Capacity_Query__c cfg = config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1);
        cfg.WSM_Filter_Logic__c = '1 AND Id != null';
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(cfg,
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'x')));

        System.assertEquals(false, def.isValid, 'Filter Logic carrying anything but numbers, AND, OR and parentheses must be rejected.');
        System.assert(def.invalidReason.contains('only filter numbers'), 'The reason should explain the allowed tokens: ' + def.invalidReason);
    }

    @isTest
    static void injection_dateLiteralIsRejected() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_LOAD, null),
            one(filter(1, 'CreatedDate', 'greater or equal', WSM_CapacityQueryBuilder.SRC_RELATIVE_DATE,
                'LAST_N_DAYS:30 OR Id != null')));

        System.assertEquals(false, def.isValid, 'A date literal with anything appended must be rejected, because date literals are inlined.');
    }

    @isTest
    static void dateLiteralWhitelist_acceptsKnownFormsAndRejectsOthers() {
        System.assertEquals(true, WSM_CapacityQueryBuilder.isWhitelistedDateLiteral('THIS_MONTH'), 'THIS_MONTH is a real literal.');
        System.assertEquals(true, WSM_CapacityQueryBuilder.isWhitelistedDateLiteral('last_n_days:7'), 'Case must not matter.');
        System.assertEquals(true, WSM_CapacityQueryBuilder.isWhitelistedDateLiteral('LAST_N_FISCAL_QUARTERS:2'), 'Fiscal forms are supported.');
        System.assertEquals(false, WSM_CapacityQueryBuilder.isWhitelistedDateLiteral('LAST_N_DAYS:'), 'A missing count is not a literal.');
        System.assertEquals(false, WSM_CapacityQueryBuilder.isWhitelistedDateLiteral('LAST_N_DAYS:99999'), 'The count is bounded to four digits.');
        System.assertEquals(false, WSM_CapacityQueryBuilder.isWhitelistedDateLiteral('SOMEDAY'), 'An invented literal is not accepted.');
        System.assertEquals(false, WSM_CapacityQueryBuilder.isWhitelistedDateLiteral(null), 'Null is not a literal.');
    }

    // ---------------------------------------------------------------- validation

    @isTest
    static void compile_rejectsNoFilters() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1), new List<WSM_Capacity_Filter__c>());

        System.assertEquals(false, def.isValid, 'A capacity query with no filters would count every record on the object.');
    }

    @isTest
    static void compile_rejectsDuplicateFilterNumbers() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1),
            new List<WSM_Capacity_Filter__c>{
                filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'a'),
                filter(1, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'b')
            });

        System.assertEquals(false, def.isValid, 'Two filters cannot share a Filter Number; Filter Logic could not tell them apart.');
    }

    @isTest
    static void compile_rejectsLogicReferencingAMissingFilter() {
        WSM_Capacity_Query__c cfg = config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1);
        cfg.WSM_Filter_Logic__c = '1 AND 9';
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(cfg,
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'a')));

        System.assertEquals(false, def.isValid, 'Logic must not reference a filter that does not exist.');
        System.assert(def.invalidReason.contains('filter 9'), 'The reason should name the missing filter: ' + def.invalidReason);
    }

    @isTest
    static void compile_rejectsUnbalancedParentheses() {
        WSM_Capacity_Query__c cfg = config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1);
        cfg.WSM_Filter_Logic__c = '(1 AND 2';
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(cfg,
            new List<WSM_Capacity_Filter__c>{
                filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'a'),
                filter(2, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'b')
            });

        System.assertEquals(false, def.isValid, 'Unbalanced parentheses must be caught at compile time, not become a QueryException.');
    }

    @isTest
    static void compile_rejectsAnOrphanedFilter() {
        WSM_Capacity_Query__c cfg = config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1);
        cfg.WSM_Filter_Logic__c = '1';
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(cfg,
            new List<WSM_Capacity_Filter__c>{
                filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'a'),
                filter(2, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'b')
            });

        System.assertEquals(false, def.isValid,
            'A filter that the logic never references is silently ignored, which is exactly the kind of quiet misconfiguration this feature exists to avoid.');
    }

    @isTest
    static void compile_rejectsLikeOnANonTextField() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1),
            one(filter(1, 'NumberOfEmployees', 'contains', WSM_CapacityQueryBuilder.SRC_LITERAL, '5')));

        System.assertEquals(false, def.isValid, 'contains cannot apply to a number field.');
    }

    @isTest
    static void compile_rejectsIncludesOnANonMultiPicklist() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1),
            one(filter(1, 'Name', 'includes', WSM_CapacityQueryBuilder.SRC_LITERAL, 'a')));

        System.assertEquals(false, def.isValid, 'includes only means something on a multi-select picklist.');
    }

    @isTest
    static void compile_rejectsAnUnparseableValue() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1),
            one(filter(1, 'NumberOfEmployees', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'not-a-number')));

        System.assertEquals(false, def.isValid, 'A value that cannot be read as the field\'s type must be rejected at compile time.');
    }

    @isTest
    static void compile_rejectsCapRoleWithNoCap() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, null),
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'a')));

        System.assertEquals(false, def.isValid, 'A Cap role with no Cap number would block nobody and mislead the admin.');
    }

    @isTest
    static void compile_rejectsRoutedFieldWithANonEqualsOperator() {
        WSM_Capacity_Filter__c f = filter(1, 'Industry', 'not equals', WSM_CapacityQueryBuilder.SRC_ROUTED_FIELD, null);
        f.WSM_Routed_Record_Field__c = 'Industry';
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1), one(f));

        System.assertEquals(false, def.isValid,
            'The routed-record count is grouped by that value, which only works for equality.');
    }

    @isTest
    static void compile_rejectsTwoRoutedFilters() {
        WSM_Capacity_Filter__c a = filter(1, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_ROUTED_FIELD, null);
        a.WSM_Routed_Record_Field__c = 'Industry';
        WSM_Capacity_Filter__c b = filter(2, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_ROUTED_FIELD, null);
        b.WSM_Routed_Record_Field__c = 'Name';
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1), new List<WSM_Capacity_Filter__c>{ a, b });

        System.assertEquals(false, def.isValid, 'Two routed-record filters would need a composite group-by; only one is supported.');
    }

    @isTest
    static void routedRecordFilter_addsTheParamKeyAndRestriction() {
        WSM_Capacity_Filter__c f = filter(1, 'Industry', 'equals', WSM_CapacityQueryBuilder.SRC_ROUTED_FIELD, null);
        f.WSM_Routed_Record_Field__c = 'Industry';
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 3), one(f));

        System.assertEquals(true, def.isValid, 'A single equals routed filter must compile. Reason: ' + def.invalidReason);
        System.assertEquals(true, def.needsRoutedValue, 'The def must advertise that it needs a routed value.');
        System.assertEquals('Industry', def.paramFieldName, 'The counted object\'s field is the group-by key.');
        System.assertEquals('Industry', def.routedFieldName, 'The routed record\'s field supplies the value.');

        String soql = WSM_CapacityQueryBuilder.toSoql(def, true);
        System.assert(soql.contains('Industry pkey'), 'The routed value must be selected as the second key: ' + soql);
        System.assert(soql.contains('GROUP BY OwnerId, Industry'), 'Both keys must be grouped: ' + soql);
        System.assert(soql.contains('Industry IN :paramValues'),
            'Restricting to the supplied values is what keeps the grouped result free of values the caller did not already know: ' + soql);
    }

    @isTest
    static void resolveRoutedFieldName_usesTheSchemaAndRejectsUnknowns() {
        System.assertEquals('Industry',
            WSM_CapacityQueryBuilder.resolveRoutedFieldName(Account.SObjectType, 'industry'),
            'A real field must resolve to the schema\'s own casing.');
        System.assertEquals(null,
            WSM_CapacityQueryBuilder.resolveRoutedFieldName(Account.SObjectType, 'NotAFieldAtAll__c'),
            'An unknown field must resolve to null so the engine can warn instead of guessing.');
        System.assertEquals(null,
            WSM_CapacityQueryBuilder.resolveRoutedFieldName(null, 'Industry'),
            'A null type must resolve to null.');
    }

    @isTest
    static void inOperator_bindsAList() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1),
            one(filter(1, 'Industry', 'in', WSM_CapacityQueryBuilder.SRC_LITERAL, 'Banking, Energy , Retail')));

        System.assertEquals(true, def.isValid, 'A comma-separated IN list must compile. Reason: ' + def.invalidReason);
        Map<String, Object> bindMap = WSM_CapacityQueryBuilder.binds(def, new Set<Id>{ UserInfo.getUserId() }, null);
        List<Object> values = (List<Object>) bindMap.get('b1');
        System.assertEquals(3, values.size(), 'Every comma-separated value must be bound, with surrounding spaces trimmed.');
        System.assertEquals('Energy', values[1], 'Values must be trimmed, not taken verbatim with spaces.');
    }

    @isTest
    static void isNullOperator_needsNoValue() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 1),
            one(filter(1, 'Industry', 'is null', WSM_CapacityQueryBuilder.SRC_LITERAL, null)));

        System.assertEquals(true, def.isValid, 'is null must compile with no Value. Reason: ' + def.invalidReason);
        String soql = WSM_CapacityQueryBuilder.toSoql(def, false);
        System.assert(soql.contains('Industry = null'), 'is null must compile to a null comparison: ' + soql);
    }

    // ---------------------------------------------------------------- the cap rule

    private static WSM_MemberState memberWithCount(Id configId, Integer count, Decimal weight) {
        WSM_Round_Robin_Member__c rec = new WSM_Round_Robin_Member__c(
            Id = WSM_Round_Robin_Member__c.SObjectType.getDescribe().getKeyPrefix() + String.valueOf(++seq).leftPad(12, '0'),
            WSM_Active__c = true,
            WSM_Weight__c = weight
        );
        WSM_MemberState state = new WSM_MemberState(rec);
        state.setCapacityCount(configId, count);
        return state;
    }

    @isTest
    static void capRule_blocksAtTheCapAndNotBelowIt() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_CAP, 20),
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'Acme')));
        WSM_GroupState grp = new WSM_GroupState(WSM_RoundRobinTestFactory.makeGroup('G', 'Strict Rotation'));
        grp.capacityQueries.add(def);

        WSM_CapacityQueryRule rule = new WSM_CapacityQueryRule();

        System.assertEquals(null, rule.evaluate(memberWithCount(def.configId, 19, 1), grp, Date.today()),
            'One under the cap must still be eligible.');
        String reason = rule.evaluate(memberWithCount(def.configId, 20, 1), grp, Date.today());
        System.assertNotEquals(null, reason, 'Exactly at the cap must be blocked.');
        System.assert(reason.startsWith('At capacity'),
            'The reason must start with "At capacity" so the log groups it with the other cap skips: ' + reason);
        System.assert(reason.contains('20/20'), 'The reason must show the reading and the cap: ' + reason);
    }

    @isTest
    static void capRule_ignoresInvalidAndLoadOnlyDefinitions() {
        WSM_CapacityQueryDef broken = WSM_CapacityQueryBuilder.compile(
            config('NotAnObject__c', WSM_CapacityQueryDef.ROLE_CAP, 1),
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'a')));
        WSM_CapacityQueryDef loadOnly = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_LOAD, null),
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'a')));

        WSM_GroupState grp = new WSM_GroupState(WSM_RoundRobinTestFactory.makeGroup('G', 'Strict Rotation'));
        grp.capacityQueries.add(broken);
        grp.capacityQueries.add(loadOnly);

        WSM_MemberState member = memberWithCount(loadOnly.configId, 9999, 1);
        member.setCapacityCount(broken.configId, 9999);

        System.assertEquals(null, new WSM_CapacityQueryRule().evaluate(member, grp, Date.today()),
            'A broken definition must not block anyone, and a Load Metric role is not a cap.');
        System.assertEquals(1, grp.capacityWarnings.size(), 'The broken definition must surface as exactly one warning.');
        System.assertEquals(true, grp.hasLoadMetric, 'The valid Load Metric definition must be detected.');
    }

    // ---------------------------------------------------------------- Least Loaded

    private static WSM_MemberState loadedMember(Decimal load, Decimal weight, Datetime lastAssigned, Decimal sortOrder) {
        WSM_Round_Robin_Member__c rec = new WSM_Round_Robin_Member__c(
            Id = WSM_Round_Robin_Member__c.SObjectType.getDescribe().getKeyPrefix() + String.valueOf(++seq).leftPad(12, '0'),
            WSM_Active__c = true,
            WSM_Weight__c = weight,
            WSM_Last_Assigned__c = lastAssigned,
            WSM_Sort_Order__c = sortOrder
        );
        WSM_MemberState state = new WSM_MemberState(rec);
        state.externalLoad = load;
        return state;
    }

    @isTest
    static void leastLoaded_picksTheLightestBook() {
        WSM_MemberState heavy = loadedMember(88, 1, null, 0);
        WSM_MemberState light = loadedMember(39, 1, null, 1);

        WSM_MemberState winner = new WSM_ExternalLoadStrategy().selectNext(new List<WSM_MemberState>{ heavy, light });

        System.assertEquals(light.record.Id, winner.record.Id, 'The member with less existing work must win.');
    }

    @isTest
    static void leastLoaded_weightBuysAProportionalShare() {
        // Weight 3 against weight 1: the heavier seat should still win at three times
        // the raw load, which is what produces a three-to-one split over time.
        WSM_MemberState weighted = loadedMember(30, 3, null, 0);
        WSM_MemberState plain = loadedMember(11, 1, null, 1);

        WSM_MemberState winner = new WSM_ExternalLoadStrategy().selectNext(new List<WSM_MemberState>{ weighted, plain });

        System.assertEquals(weighted.record.Id, winner.record.Id,
            'Load divided by weight is 10 against 11, so the weight-3 seat is still the cheaper choice.');
    }

    @isTest
    static void leastLoaded_tiesFallThroughToRotation() {
        WSM_MemberState older = loadedMember(10, 1, Datetime.newInstance(2026, 1, 1, 0, 0, 0), 1);
        WSM_MemberState newer = loadedMember(10, 1, Datetime.newInstance(2026, 6, 1, 0, 0, 0), 0);

        WSM_MemberState winner = new WSM_ExternalLoadStrategy().selectNext(new List<WSM_MemberState>{ newer, older });

        System.assertEquals(older.record.Id, winner.record.Id,
            'Equal load must fall through to Last Assigned so repeated calls alternate instead of stacking.');
    }

    @isTest
    static void leastLoaded_nullWeightAndNullLoadAreSafe() {
        WSM_MemberState noWeight = loadedMember(null, null, null, 0);
        WSM_MemberState loaded = loadedMember(5, 1, null, 1);

        WSM_MemberState winner = new WSM_ExternalLoadStrategy().selectNext(new List<WSM_MemberState>{ loaded, noWeight });

        System.assertEquals(noWeight.record.Id, winner.record.Id, 'A blank weight and a blank load must behave as 1 and 0, not throw.');
        System.assertEquals(null, new WSM_ExternalLoadStrategy().selectNext(new List<WSM_MemberState>()),
            'An empty pool must return null rather than throwing.');
    }

    // ---------------------------------------------------------------- load maths

    @isTest
    static void externalLoad_sumsMetricsByTheirLoadWeight() {
        WSM_Capacity_Query__c cfgA = config('Account', WSM_CapacityQueryDef.ROLE_LOAD, null);
        cfgA.WSM_Load_Weight__c = 1;
        WSM_Capacity_Query__c cfgB = config('Account', WSM_CapacityQueryDef.ROLE_LOAD, null);
        cfgB.WSM_Load_Weight__c = 2.5;

        WSM_CapacityQueryDef defA = WSM_CapacityQueryBuilder.compile(cfgA,
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'a')));
        WSM_CapacityQueryDef defB = WSM_CapacityQueryBuilder.compile(cfgB,
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'b')));
        List<WSM_CapacityQueryDef> defs = new List<WSM_CapacityQueryDef>{ defA, defB };

        WSM_MemberState member = memberWithCount(defA.configId, 4, 1);
        member.setCapacityCount(defB.configId, 2);
        member.recomputeExternalLoad(defs);

        System.assertEquals(9, member.externalLoad, '4 at weight 1 plus 2 at weight 2.5 is 9.');

        member.chargeOnePick(defs);
        System.assertEquals(12.5, member.externalLoad,
            'Charging one pick must add one to every load metric (5 + 7.5), so a bulk batch levels out within the transaction.');
    }

    @isTest
    static void loadWeightDefaultsToOne() {
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(
            config('Account', WSM_CapacityQueryDef.ROLE_BOTH, 10),
            one(filter(1, 'Name', 'equals', WSM_CapacityQueryBuilder.SRC_LITERAL, 'a')));

        System.assertEquals(1, def.loadWeight, 'A blank Load Weight must behave as 1.');
        System.assertEquals(true, def.isCap, 'The combined role must be a cap.');
        System.assertEquals(true, def.isLoadMetric, 'The combined role must also be a load metric.');
    }

    // ---------------------------------------------------------------- strategy factory

    @isTest
    static void factory_leastLoadedNeedsALoadMetric() {
        List<String> warnings = new List<String>();
        WSM_ISelectionStrategy withMetric = WSM_StrategyFactory.create(
            WSM_StrategyFactory.LEAST_LOADED, 'None', true, warnings);
        System.assert(withMetric instanceof WSM_ExternalLoadStrategy, 'With a load metric, Least Loaded must be used.');
        System.assertEquals(0, warnings.size(), 'A correctly configured group must not warn.');

        List<String> fallbackWarnings = new List<String>();
        WSM_ISelectionStrategy withoutMetric = WSM_StrategyFactory.create(
            WSM_StrategyFactory.LEAST_LOADED, 'None', false, fallbackWarnings);
        System.assert(withoutMetric instanceof WSM_StrictRotationStrategy,
            'Least Loaded with nothing to rank on must degrade to Strict Rotation rather than silently ranking everyone at zero.');
        System.assertEquals(1, fallbackWarnings.size(), 'The degradation must be warned about.');
    }

    @isTest
    static void tier_blankCountsAsOne() {
        WSM_GroupState grp = new WSM_GroupState(WSM_RoundRobinTestFactory.makeGroup('G', 'Strict Rotation'));
        WSM_MemberState blank = memberWithCount(null, 0, 1);
        WSM_Round_Robin_Member__c tiered = blank.record.clone(false, true, false, false);
        tiered.WSM_Tier__c = 2;
        grp.members.add(blank);
        grp.members.add(new WSM_MemberState(tiered));

        System.assertEquals(1, blank.tier, 'A blank Tier must behave as tier 1 so existing groups keep working.');
        System.assertEquals(new List<Integer>{ 1, 2 }, grp.tiers, 'Tiers must come back ascending and de-duplicated.');
    }
}
