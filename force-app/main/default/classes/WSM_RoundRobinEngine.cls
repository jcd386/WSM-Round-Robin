/**
 * Runs without sharing because it's invoked from Flow/Process/Invocable contexts that
 * can execute as guest users, community users, or automation service accounts with no
 * access of their own to the WSM_ objects (e.g. a public Web-to-Case flow routing a new
 * Case needs to read the group/member config and write the winning member + a log row,
 * even though the guest running user has no direct sharing on WSM_Round_Robin_Group__c).
 *
 * Scope of that elevated access, which Capacity Queries widened deliberately in 2.2:
 *   - The package's own WSM_ objects, read and written freely, as before.
 *   - The customer's objects, read in two tightly bounded ways only. Capacity Queries run
 *     COUNT(Id) aggregates grouped by an owner field, so they return tallies and never
 *     record content. A capacity query whose value comes off the routed record also reads
 *     the fields its own config names, only from the record Ids the caller explicitly
 *     passed in as Assigned Record Id. Those values are used to build the count and are
 *     never written to the assignment log.
 * Both reads are SYSTEM_MODE by necessity: in the guest and community contexts this
 * package is built for, the running user frequently cannot read the record they just
 * created, and a USER_MODE count would come back zero and misroute silently. The narrow
 * shape above is what keeps that honest. See WSM_RoundRobinSelector for the queries.
 *
 * Fixed query/DML footprint per assign() call, flat in both batch size and pool size:
 * resolve (0-1) + lock (1-2, with retry) + members (0-1) + period aggregates (0-3) +
 * capacity config (0-1) + one aggregate per active capacity query (capped per group at
 * MAX_CAPACITY_QUERIES_PER_GROUP) + one routed-record read per distinct routed object
 * type, and at most one member update + one log insert.
 */
public without sharing class WSM_RoundRobinEngine {

    /** Ceiling on capacity queries evaluated per group, so one group cannot blow the SOQL limit. */
    @TestVisible
    private static final Integer MAX_CAPACITY_QUERIES_PER_GROUP = 5;

    @TestVisible
    private WSM_RoundRobinSelector selector = new WSM_RoundRobinSelector();

    private List<WSM_RRResult> results;
    private List<WSM_Assignment_Log__c> logsToInsert;
    private List<WSM_RRResult> resultsByLogIndex;

    /** configId -> (member user Id -> count), for capacity queries with no routed-record input. */
    private Map<Id, Map<Id, Integer>> plainCountsByConfig;

    /** configId -> ("userId|paramValue" -> count), for capacity queries keyed off the routed record. */
    private Map<Id, Map<String, Integer>> paramCountsByConfig;

    /** request index -> (configId -> the routed record's value for that config). */
    private Map<Integer, Map<Id, Object>> routedValueByRequest;

    /** Per-group configuration warnings, merged onto every log row for that group. */
    private Map<Id, List<String>> configWarningsByGroup;

    public List<WSM_RRResult> assign(List<WSM_RRRequest> requests) {
        results = new List<WSM_RRResult>();
        logsToInsert = new List<WSM_Assignment_Log__c>();
        resultsByLogIndex = new List<WSM_RRResult>();
        resetCapacityState();

        if (requests == null || requests.isEmpty()) {
            return results;
        }
        for (Integer i = 0; i < requests.size(); i++) {
            results.add(null);
        }

        Map<Integer, Id> groupIdByIndex = resolveGroupIds(requests);
        Set<Id> groupIdsToLock = new Set<Id>(groupIdByIndex.values());
        List<WSM_Round_Robin_Member__c> membersToUpdate = new List<WSM_Round_Robin_Member__c>();

        if (!groupIdsToLock.isEmpty()) {
            Map<Id, WSM_Round_Robin_Group__c> lockedGroups = lockGroupsWithRetry(groupIdsToLock);

            if (lockedGroups == null) {
                for (Integer i : groupIdByIndex.keySet()) {
                    Id gid = groupIdByIndex.get(i);
                    WSM_RRResult result = errorResult(WSM_RRResult.STATUS_LOCK_TIMEOUT, gid,
                        'Could not lock the group for update after one retry.');
                    finalize(i, result, WSM_AssignmentLogger.buildLog(gid, null, null, null,
                        WSM_AssignmentLogger.LOG_STATUS_ERROR, requests[i], result.message));
                }
            } else {
                Map<Id, WSM_GroupState> groupStates = buildGroupStates(groupIdsToLock, lockedGroups);
                loadCapacityQueries(groupStates);
                gatherRoutedValues(requests, groupIdByIndex, groupStates);
                runCapacityAggregates(groupStates);
                processGroupRequests(requests, groupIdByIndex, lockedGroups, groupStates, membersToUpdate);
            }
        }

        if (!membersToUpdate.isEmpty()) {
            update membersToUpdate;
        }
        if (!logsToInsert.isEmpty()) {
            insert logsToInsert;
            for (Integer i = 0; i < logsToInsert.size(); i++) {
                resultsByLogIndex[i].logId = logsToInsert[i].Id;
            }
        }
        return results;
    }

    /**
     * Dry run for one group: no lock, no DML. Uses the same eligibility pipeline, tier
     * walk and strategy ranking as assign() so the preview matches what a real call would
     * do. Capacity queries that need a value off a routed record cannot be evaluated here
     * (there is no record), so they come back with an unavailableReason rather than a
     * misleading zero.
     */
    public WSM_RRPreview preview(Id groupId) {
        WSM_RRPreview preview = new WSM_RRPreview();
        preview.groupId = groupId;
        if (groupId == null) {
            return preview;
        }
        resetCapacityState();

        List<WSM_Round_Robin_Group__c> groups = selector.queryGroups(new Set<Id>{ groupId });
        if (groups.isEmpty()) {
            return preview;
        }
        WSM_Round_Robin_Group__c groupRecord = groups[0];

        WSM_GroupState groupState = new WSM_GroupState(groupRecord);
        for (WSM_Round_Robin_Member__c mr : selector.membersForGroups(new Set<Id>{ groupId })) {
            groupState.members.add(new WSM_MemberState(mr));
        }
        Map<Id, WSM_GroupState> groupStates = new Map<Id, WSM_GroupState>{ groupId => groupState };
        applyPeriodCounts(groupStates);
        loadCapacityQueries(groupStates);
        runCapacityAggregates(groupStates);
        applyPlainCounts(groupState);

        preview.warnings.addAll(groupState.capacityWarnings);
        List<String> configWarnings = configWarningsByGroup.get(groupId);
        if (configWarnings != null) {
            preview.warnings.addAll(configWarnings);
        }

        WSM_EligibilityPipeline pipeline = WSM_EligibilityPipeline.defaultPipeline();
        Date today = Date.today();
        List<String> warnings = new List<String>();
        WSM_ISelectionStrategy strategy = WSM_StrategyFactory.create(
            groupRecord.WSM_Algorithm__c, groupRecord.WSM_Calibration__c, groupState.hasLoadMetric, warnings);
        preview.warnings.addAll(warnings);

        Map<Id, String> reasonByMember = new Map<Id, String>();
        Map<Id, Integer> rankByMember = new Map<Id, Integer>();
        Set<Integer> tiersEvaluated = new Set<Integer>();

        for (Integer tier : groupState.tiers) {
            tiersEvaluated.add(tier);
            List<WSM_MemberState> eligible = new List<WSM_MemberState>();
            for (WSM_MemberState ms : groupState.members) {
                if (ms.tier != tier) {
                    continue;
                }
                String reason = pipeline.evaluate(ms, groupState, today);
                if (reason == null) {
                    eligible.add(ms);
                } else {
                    reasonByMember.put(ms.record.Id, reason);
                }
            }
            if (eligible.isEmpty()) {
                continue;
            }
            List<WSM_MemberState> ranked = strategy.sortMembers(eligible);
            for (Integer i = 0; i < ranked.size(); i++) {
                rankByMember.put(ranked[i].record.Id, i + 1);
            }
            if (groupRecord.WSM_Active__c == true) {
                preview.wouldAssignMemberId = ranked[0].record.Id;
                preview.wouldAssignUserId = ranked[0].record.WSM_User__c;
                preview.assignedFromTier = tier;
            }
            break;
        }

        for (WSM_MemberState ms : groupState.members) {
            WSM_RRPreview.MemberVerdict verdict = new WSM_RRPreview.MemberVerdict();
            verdict.memberId = ms.record.Id;
            verdict.userId = ms.record.WSM_User__c;
            verdict.userName = ms.record.WSM_User__r != null ? ms.record.WSM_User__r.Name : null;
            verdict.tier = ms.tier;
            verdict.tierReached = tiersEvaluated.contains(ms.tier);
            verdict.externalLoad = ms.externalLoad;
            verdict.eligible = !reasonByMember.containsKey(ms.record.Id);
            verdict.skipReason = verdict.eligible ? '' : reasonByMember.get(ms.record.Id);
            verdict.sortRank = rankByMember.get(ms.record.Id);
            verdict.capacity = capacityReadingsFor(groupState, ms);
            preview.verdicts.add(verdict);
        }
        return preview;
    }

    private List<WSM_RRPreview.CapacityReading> capacityReadingsFor(WSM_GroupState groupState, WSM_MemberState member) {
        List<WSM_RRPreview.CapacityReading> readings = new List<WSM_RRPreview.CapacityReading>();
        for (WSM_CapacityQueryDef def : groupState.capacityQueries) {
            if (def.isValid != true) {
                continue;
            }
            WSM_RRPreview.CapacityReading reading = new WSM_RRPreview.CapacityReading();
            reading.capacityQueryId = def.configId;
            reading.label = def.label;
            reading.cap = def.cap;
            reading.isCap = def.isCap;
            reading.isLoadMetric = def.isLoadMetric;
            if (def.needsRoutedValue) {
                reading.unavailableReason = 'Needs a value from the record being routed, so it cannot be previewed.';
                reading.count = null;
                reading.atCap = false;
            } else {
                reading.count = member.capacityCount(def.configId);
                reading.atCap = def.isCap && def.cap != null && reading.count >= def.cap;
            }
            readings.add(reading);
        }
        return readings;
    }

    // ------------------------------------------------------------ capacity loading

    private void resetCapacityState() {
        plainCountsByConfig = new Map<Id, Map<Id, Integer>>();
        paramCountsByConfig = new Map<Id, Map<String, Integer>>();
        routedValueByRequest = new Map<Integer, Map<Id, Object>>();
        configWarningsByGroup = new Map<Id, List<String>>();
    }

    /** One query for every group's capacity config, then compile each row against the schema. */
    private void loadCapacityQueries(Map<Id, WSM_GroupState> groupStates) {
        if (groupStates.isEmpty()) {
            return;
        }
        List<WSM_Capacity_Query__c> configs;
        try {
            configs = selector.capacityQueriesForGroups(groupStates.keySet());
        } catch (Exception configReadFailure) {
            // The capacity objects are part of this package, so this should not happen.
            // If it somehow does, routing must carry on exactly as it did before 2.2.
            for (Id gid : groupStates.keySet()) {
                addConfigWarning(gid, 'Capacity queries could not be read: ' + configReadFailure.getMessage());
            }
            return;
        }

        Map<Id, Integer> acceptedByGroup = new Map<Id, Integer>();
        for (WSM_Capacity_Query__c config : configs) {
            WSM_GroupState groupState = groupStates.get(config.WSM_Group__c);
            if (groupState == null) {
                continue;
            }
            Integer accepted = acceptedByGroup.containsKey(config.WSM_Group__c) ? acceptedByGroup.get(config.WSM_Group__c) : 0;
            if (accepted >= MAX_CAPACITY_QUERIES_PER_GROUP) {
                addConfigWarning(config.WSM_Group__c, 'More than ' + MAX_CAPACITY_QUERIES_PER_GROUP
                    + ' active capacity queries; \'' + config.WSM_Label__c + '\' and any after it were not evaluated.');
                continue;
            }
            acceptedByGroup.put(config.WSM_Group__c, accepted + 1);
            groupState.capacityQueries.add(
                WSM_CapacityQueryBuilder.compile(config, config.Filters__r));
        }
    }

    /**
     * Reads the routed records once per distinct object type and pins each request's value
     * for each capacity query that needs one. Requests with no Assigned Record Id, an
     * unreadable Id, or a field the routed object does not have simply end up without a
     * value; runCapacityAggregates and applyParamCounts then treat that capacity query as
     * unevaluated for those requests and say so in the log.
     */
    private void gatherRoutedValues(List<WSM_RRRequest> requests, Map<Integer, Id> groupIdByIndex,
            Map<Id, WSM_GroupState> groupStates) {

        Map<SObjectType, Set<Id>> idsByType = new Map<SObjectType, Set<Id>>();
        Map<Integer, Id> routedIdByIndex = new Map<Integer, Id>();

        for (Integer i : groupIdByIndex.keySet()) {
            WSM_GroupState groupState = groupStates.get(groupIdByIndex.get(i));
            if (groupState == null || !needsAnyRoutedValue(groupState)) {
                continue;
            }
            String raw = requests[i] == null ? null : requests[i].assignedRecordId;
            if (String.isBlank(raw)) {
                continue;
            }
            Id routedId;
            try {
                routedId = Id.valueOf(raw.trim());
            } catch (Exception badId) {
                continue;
            }
            SObjectType routedType = routedId.getSObjectType();
            if (routedType == null) {
                continue;
            }
            routedIdByIndex.put(i, routedId);
            if (!idsByType.containsKey(routedType)) {
                idsByType.put(routedType, new Set<Id>());
            }
            idsByType.get(routedType).add(routedId);
        }

        if (routedIdByIndex.isEmpty()) {
            return;
        }

        // Resolve the field names each type needs, then one read per type.
        Map<Id, SObject> recordById = new Map<Id, SObject>();
        Map<SObjectType, Map<String, String>> resolvedByType = new Map<SObjectType, Map<String, String>>();

        for (SObjectType routedType : idsByType.keySet()) {
            Map<String, String> resolved = new Map<String, String>();
            for (WSM_GroupState groupState : groupStates.values()) {
                for (WSM_CapacityQueryDef def : groupState.capacityQueries) {
                    if (def.isValid != true || !def.needsRoutedValue) {
                        continue;
                    }
                    String schemaName = WSM_CapacityQueryBuilder.resolveRoutedFieldName(routedType, def.routedFieldName);
                    if (schemaName != null) {
                        resolved.put(def.routedFieldName, schemaName);
                    }
                }
            }
            resolvedByType.put(routedType, resolved);
            if (resolved.isEmpty()) {
                continue;
            }
            try {
                for (SObject record : selector.routedRecords(routedType.getDescribe().getName(),
                        new Set<String>(resolved.values()), idsByType.get(routedType))) {
                    recordById.put((Id) record.get('Id'), record);
                }
            } catch (Exception routedReadFailure) {
                for (Id gid : groupStates.keySet()) {
                    addConfigWarning(gid, 'Could not read the routed '
                        + routedType.getDescribe().getName() + ': ' + routedReadFailure.getMessage());
                }
            }
        }

        for (Integer i : routedIdByIndex.keySet()) {
            Id routedId = routedIdByIndex.get(i);
            SObject record = recordById.get(routedId);
            if (record == null) {
                continue;
            }
            Map<String, String> resolved = resolvedByType.get(routedId.getSObjectType());
            WSM_GroupState groupState = groupStates.get(groupIdByIndex.get(i));
            Map<Id, Object> valueByConfig = new Map<Id, Object>();
            for (WSM_CapacityQueryDef def : groupState.capacityQueries) {
                if (def.isValid != true || !def.needsRoutedValue) {
                    continue;
                }
                String schemaName = resolved == null ? null : resolved.get(def.routedFieldName);
                if (schemaName == null) {
                    continue;
                }
                Object value = record.get(schemaName);
                if (value != null) {
                    valueByConfig.put(def.configId, value);
                }
            }
            if (!valueByConfig.isEmpty()) {
                routedValueByRequest.put(i, valueByConfig);
            }
        }
    }

    private Boolean needsAnyRoutedValue(WSM_GroupState groupState) {
        for (WSM_CapacityQueryDef def : groupState.capacityQueries) {
            if (def.isValid == true && def.needsRoutedValue) {
                return true;
            }
        }
        return false;
    }

    /**
     * One aggregate per valid capacity query. Routed-record queries are restricted to the
     * values the caller already supplied and grouped by that value, which keeps it to a
     * single query for the whole batch and keeps the result free of any value the caller
     * did not already know.
     */
    private void runCapacityAggregates(Map<Id, WSM_GroupState> groupStates) {
        for (WSM_GroupState groupState : groupStates.values()) {
            Set<Id> ownerIds = new Set<Id>();
            for (WSM_MemberState member : groupState.members) {
                if (member.record.WSM_User__c != null) {
                    ownerIds.add(member.record.WSM_User__c);
                }
            }
            if (ownerIds.isEmpty()) {
                continue;
            }

            for (WSM_CapacityQueryDef def : groupState.capacityQueries) {
                if (def.isValid != true) {
                    continue;
                }
                Set<Object> paramValues = new Set<Object>();
                if (def.needsRoutedValue) {
                    for (Map<Id, Object> valueByConfig : routedValueByRequest.values()) {
                        Object value = valueByConfig.get(def.configId);
                        if (value != null) {
                            paramValues.add(value);
                        }
                    }
                    if (paramValues.isEmpty()) {
                        // Nothing to count against. Left unevaluated on purpose: blocking
                        // every member because one input was missing would be worse than
                        // routing and saying so on the log.
                        continue;
                    }
                }

                String soql = WSM_CapacityQueryBuilder.toSoql(def, def.needsRoutedValue);
                if (String.isBlank(soql)) {
                    continue;
                }
                try {
                    Map<String, Object> bindMap = WSM_CapacityQueryBuilder.binds(def, ownerIds, paramValues);
                    List<AggregateResult> rows = selector.capacityAggregate(soql, bindMap);
                    if (def.needsRoutedValue) {
                        Map<String, Integer> byKey = new Map<String, Integer>();
                        for (AggregateResult row : rows) {
                            byKey.put(paramKey((Id) row.get(WSM_CapacityQueryBuilder.GROUP_KEY_ALIAS),
                                    row.get(WSM_CapacityQueryBuilder.PARAM_KEY_ALIAS)),
                                (Integer) row.get(WSM_CapacityQueryBuilder.COUNT_ALIAS));
                        }
                        paramCountsByConfig.put(def.configId, byKey);
                    } else {
                        Map<Id, Integer> byOwner = new Map<Id, Integer>();
                        for (AggregateResult row : rows) {
                            byOwner.put((Id) row.get(WSM_CapacityQueryBuilder.GROUP_KEY_ALIAS),
                                (Integer) row.get(WSM_CapacityQueryBuilder.COUNT_ALIAS));
                        }
                        plainCountsByConfig.put(def.configId, byOwner);
                    }
                } catch (Exception aggregateFailure) {
                    // Compile-time validation covers the shapes we can check statically;
                    // anything that still fails at runtime (field-level platform quirks,
                    // a filter the optimizer rejects) degrades this one count instead of
                    // failing the assignment.
                    def.isValid = false;
                    def.invalidReason = 'Query failed: ' + aggregateFailure.getMessage();
                }
            }
        }
    }

    private static String paramKey(Id ownerId, Object paramValue) {
        return String.valueOf(ownerId) + '|' + String.valueOf(paramValue);
    }

    /** Applies the routed-record-independent counts, which are the same for every request. */
    private void applyPlainCounts(WSM_GroupState groupState) {
        for (WSM_MemberState member : groupState.members) {
            for (WSM_CapacityQueryDef def : groupState.capacityQueries) {
                if (def.isValid != true || def.needsRoutedValue) {
                    continue;
                }
                Map<Id, Integer> byOwner = plainCountsByConfig.get(def.configId);
                Integer count = byOwner == null ? 0 : byOwner.get(member.record.WSM_User__c);
                member.setCapacityCount(def.configId, count == null ? 0 : count);
            }
            member.recomputeExternalLoad(groupState.capacityQueries);
        }
    }

    /**
     * Overlays this request's routed-record-dependent counts. Returns the labels of any
     * capacity query that could not be evaluated for this request so the log can say so.
     */
    private List<String> applyParamCounts(WSM_GroupState groupState, Integer requestIndex) {
        List<String> unevaluated = new List<String>();
        Map<Id, Object> valueByConfig = routedValueByRequest.get(requestIndex);

        for (WSM_CapacityQueryDef def : groupState.capacityQueries) {
            if (def.isValid != true || !def.needsRoutedValue) {
                continue;
            }
            Object paramValue = valueByConfig == null ? null : valueByConfig.get(def.configId);
            if (paramValue == null) {
                unevaluated.add(def.label);
                for (WSM_MemberState member : groupState.members) {
                    member.setCapacityCount(def.configId, 0);
                }
                continue;
            }
            Map<String, Integer> byKey = paramCountsByConfig.get(def.configId);
            for (WSM_MemberState member : groupState.members) {
                Integer count = byKey == null ? null : byKey.get(paramKey(member.record.WSM_User__c, paramValue));
                member.setCapacityCount(def.configId, count == null ? 0 : count);
            }
        }
        if (!unevaluated.isEmpty() || valueByConfig != null) {
            for (WSM_MemberState member : groupState.members) {
                member.recomputeExternalLoad(groupState.capacityQueries);
            }
        }
        return unevaluated;
    }

    private void addConfigWarning(Id groupId, String warning) {
        if (!configWarningsByGroup.containsKey(groupId)) {
            configWarningsByGroup.put(groupId, new List<String>());
        }
        configWarningsByGroup.get(groupId).add(warning);
    }

    // ------------------------------------------------------------ existing pipeline

    private void finalize(Integer index, WSM_RRResult result, WSM_Assignment_Log__c logRow) {
        results[index] = result;
        logsToInsert.add(logRow);
        resultsByLogIndex.add(result);
    }

    private Map<Integer, Id> resolveGroupIds(List<WSM_RRRequest> requests) {
        Set<String> devNamesNeeded = new Set<String>();
        for (WSM_RRRequest req : requests) {
            if (req != null && req.groupId == null && String.isNotBlank(req.groupDeveloperName)) {
                devNamesNeeded.add(req.groupDeveloperName);
            }
        }

        Map<String, Id> groupIdByDevName = new Map<String, Id>();
        if (!devNamesNeeded.isEmpty()) {
            for (WSM_Round_Robin_Group__c g : selector.resolveDeveloperNames(devNamesNeeded)) {
                if (String.isNotBlank(g.WSM_Developer_Name__c)) {
                    groupIdByDevName.put(g.WSM_Developer_Name__c.toLowerCase(), g.Id);
                }
            }
        }

        Map<Integer, Id> resolved = new Map<Integer, Id>();
        for (Integer i = 0; i < requests.size(); i++) {
            WSM_RRRequest req = requests[i];
            Id gid = req == null ? null : req.groupId;
            if (gid == null && req != null && String.isNotBlank(req.groupDeveloperName)) {
                gid = groupIdByDevName.get(req.groupDeveloperName.toLowerCase());
            }
            if (gid == null) {
                WSM_RRResult result = errorResult(WSM_RRResult.STATUS_GROUP_NOT_FOUND, null,
                    'No Round Robin Group found for the supplied Id or developer name.');
                finalize(i, result, WSM_AssignmentLogger.buildLog(null, null, null, null,
                    WSM_AssignmentLogger.LOG_STATUS_ERROR, req, result.message));
            } else {
                resolved.put(i, gid);
            }
        }
        return resolved;
    }

    /** One lock attempt, one retry on QueryException (UNABLE_TO_LOCK_ROW), then give up. */
    private Map<Id, WSM_Round_Robin_Group__c> lockGroupsWithRetry(Set<Id> groupIds) {
        try {
            return new Map<Id, WSM_Round_Robin_Group__c>(selector.lockGroups(groupIds));
        } catch (QueryException firstFailure) {
            try {
                return new Map<Id, WSM_Round_Robin_Group__c>(selector.lockGroups(groupIds));
            } catch (QueryException secondFailure) {
                return null;
            }
        }
    }

    private Map<Id, WSM_GroupState> buildGroupStates(Set<Id> groupIds, Map<Id, WSM_Round_Robin_Group__c> lockedGroups) {
        Map<Id, WSM_GroupState> groupStates = new Map<Id, WSM_GroupState>();
        for (Id gid : groupIds) {
            if (lockedGroups.containsKey(gid)) {
                groupStates.put(gid, new WSM_GroupState(lockedGroups.get(gid)));
            }
        }
        if (groupStates.isEmpty()) {
            return groupStates;
        }

        for (WSM_Round_Robin_Member__c mr : selector.membersForGroups(groupStates.keySet())) {
            WSM_GroupState gs = groupStates.get(mr.WSM_Group__c);
            if (gs != null) {
                gs.members.add(new WSM_MemberState(mr));
            }
        }

        applyPeriodCounts(groupStates);
        return groupStates;
    }

    /** One aggregate query per distinct period-start value across all the groups given (≤3: Daily/Weekly/Monthly). */
    private void applyPeriodCounts(Map<Id, WSM_GroupState> groupStates) {
        Map<Datetime, Set<Id>> groupIdsByPeriodStart = new Map<Datetime, Set<Id>>();
        for (WSM_GroupState gs : groupStates.values()) {
            Datetime periodStart = periodStartFor(gs.record.WSM_Period__c);
            if (!groupIdsByPeriodStart.containsKey(periodStart)) {
                groupIdsByPeriodStart.put(periodStart, new Set<Id>());
            }
            groupIdsByPeriodStart.get(periodStart).add(gs.record.Id);
        }

        Map<Id, WSM_MemberState> memberStateById = new Map<Id, WSM_MemberState>();
        for (WSM_GroupState gs : groupStates.values()) {
            for (WSM_MemberState ms : gs.members) {
                memberStateById.put(ms.record.Id, ms);
            }
        }

        for (Datetime periodStart : groupIdsByPeriodStart.keySet()) {
            for (AggregateResult ar : selector.periodCounts(groupIdsByPeriodStart.get(periodStart), periodStart)) {
                WSM_MemberState ms = memberStateById.get((Id) ar.get('memberId'));
                if (ms != null) {
                    ms.periodCount = (Integer) ar.get('cnt');
                }
            }
        }
    }

    private void processGroupRequests(List<WSM_RRRequest> requests, Map<Integer, Id> groupIdByIndex,
            Map<Id, WSM_Round_Robin_Group__c> lockedGroups, Map<Id, WSM_GroupState> groupStates,
            List<WSM_Round_Robin_Member__c> membersToUpdate) {
        Datetime txnBase = Datetime.now();
        WSM_EligibilityPipeline pipeline = WSM_EligibilityPipeline.defaultPipeline();
        Date today = Date.today();

        for (WSM_GroupState gs : groupStates.values()) {
            applyPlainCounts(gs);
        }

        for (Integer i = 0; i < requests.size(); i++) {
            if (!groupIdByIndex.containsKey(i)) {
                continue;
            }
            try {
                processOneRequest(i, requests[i], groupIdByIndex.get(i), lockedGroups, groupStates, pipeline, today, txnBase);
            } catch (Exception unexpected) {
                // One bad request (unexpected null/data issue) must never abort the rest of
                // the batch — isolate it as an ERROR result + log and keep going.
                Id gid = groupIdByIndex.get(i);
                WSM_RRResult result = errorResult(WSM_RRResult.STATUS_ERROR, gid, 'Unexpected error: ' + unexpected.getMessage());
                finalize(i, result, WSM_AssignmentLogger.buildLog(gid, null, null, null,
                    WSM_AssignmentLogger.LOG_STATUS_ERROR, requests[i], result.message));
            }
        }

        for (WSM_GroupState gs : groupStates.values()) {
            membersToUpdate.addAll(gs.dirtyRecords());
        }
    }

    private void processOneRequest(Integer i, WSM_RRRequest req, Id gid, Map<Id, WSM_Round_Robin_Group__c> lockedGroups,
            Map<Id, WSM_GroupState> groupStates, WSM_EligibilityPipeline pipeline, Date today, Datetime txnBase) {
        if (!lockedGroups.containsKey(gid)) {
            WSM_RRResult result = errorResult(WSM_RRResult.STATUS_GROUP_NOT_FOUND, gid, 'Round Robin Group not found.');
            // The group lookup stays null: gid may reference a deleted row, and a populated
            // lookup to it would fail the whole log insert with ENTITY_IS_DELETED.
            finalize(i, result, WSM_AssignmentLogger.buildLog(null, null, null, null,
                WSM_AssignmentLogger.LOG_STATUS_ERROR, req, result.message + ' Requested group: ' + gid));
            return;
        }

        WSM_GroupState groupState = groupStates.get(gid);
        WSM_Round_Robin_Group__c groupRecord = groupState.record;

        if (groupRecord.WSM_Active__c != true) {
            WSM_RRResult result = errorResult(WSM_RRResult.STATUS_GROUP_INACTIVE, gid, 'Round Robin Group is inactive.');
            finalize(i, result, WSM_AssignmentLogger.buildLog(gid, null, null, groupRecord.WSM_Algorithm__c,
                WSM_AssignmentLogger.LOG_STATUS_ERROR, req, result.message));
            return;
        }

        List<String> notes = new List<String>();
        notes.addAll(groupState.capacityWarnings);
        if (configWarningsByGroup.containsKey(gid)) {
            notes.addAll(configWarningsByGroup.get(gid));
        }
        for (String label : applyParamCounts(groupState, i)) {
            notes.add('Capacity query \'' + label + '\' was not applied: no value for it on the routed record.');
        }

        WSM_ISelectionStrategy strategy = WSM_StrategyFactory.create(
            groupRecord.WSM_Algorithm__c, groupRecord.WSM_Calibration__c, groupState.hasLoadMetric, notes);

        // Tier walk: fill the lowest tier that has anyone eligible and stop. Higher tiers
        // are never evaluated when a lower one can take the work, which is what makes an
        // overflow bench a bench rather than part of the rotation.
        WSM_MemberState winner = null;
        Integer winningTier = null;
        Map<Id, String> skipReasonByMember = new Map<Id, String>();

        for (Integer tier : groupState.tiers) {
            List<WSM_MemberState> eligible = new List<WSM_MemberState>();
            for (WSM_MemberState ms : groupState.members) {
                if (ms.tier != tier) {
                    continue;
                }
                String reason = pipeline.evaluate(ms, groupState, today);
                if (reason == null) {
                    eligible.add(ms);
                } else {
                    skipReasonByMember.put(ms.record.Id, reason);
                }
            }
            if (eligible.isEmpty()) {
                continue;
            }
            winner = strategy.selectNext(eligible);
            winningTier = tier;
            break;
        }

        if (winner == null) {
            String skipSummary = WSM_AssignmentLogger.buildSkipSummary(skipReasonByMember);
            String detail = joinDetail(skipSummary, notes);
            if (groupRecord.WSM_Fallback_User__c != null) {
                WSM_RRResult result = new WSM_RRResult(true, WSM_RRResult.STATUS_FALLBACK, gid);
                result.userId = groupRecord.WSM_Fallback_User__c;
                result.message = 'No eligible members; routed to the fallback user.';
                finalize(i, result, WSM_AssignmentLogger.buildLog(gid, null, groupRecord.WSM_Fallback_User__c,
                    groupRecord.WSM_Algorithm__c, WSM_AssignmentLogger.LOG_STATUS_FALLBACK, req, detail));
            } else if (String.isNotBlank(groupRecord.WSM_Fallback_Queue_Id__c)) {
                WSM_RRResult result = new WSM_RRResult(true, WSM_RRResult.STATUS_FALLBACK, gid);
                result.queueId = groupRecord.WSM_Fallback_Queue_Id__c;
                result.message = 'No eligible members; routed to the fallback queue.';
                String queueDetail = 'Routed to fallback queue ' + groupRecord.WSM_Fallback_Queue_Id__c
                    + (String.isBlank(detail) ? '' : '. ' + detail);
                finalize(i, result, WSM_AssignmentLogger.buildLog(gid, null, null,
                    groupRecord.WSM_Algorithm__c, WSM_AssignmentLogger.LOG_STATUS_FALLBACK, req, queueDetail));
            } else {
                WSM_RRResult result = errorResult(WSM_RRResult.STATUS_NO_ELIGIBLE_MEMBERS, gid,
                    'No eligible members and no fallback user configured.');
                finalize(i, result, WSM_AssignmentLogger.buildLog(gid, null, null, groupRecord.WSM_Algorithm__c,
                    WSM_AssignmentLogger.LOG_STATUS_NO_ELIGIBLE_MEMBERS, req, detail));
            }
            return;
        }

        // Replayable stamping: all picks in this group during this call share txnBase but
        // get a strictly increasing one-SECOND offset. Whole seconds, not milliseconds:
        // Salesforce truncates milliseconds when persisting Datetime fields, which would
        // collapse a bulk batch's stamps into ties and lose the rotation order on replay.
        winner.lastAssigned = Datetime.newInstance(txnBase.getTime() + (groupState.msSequence * 1000));
        groupState.msSequence++;
        winner.periodCount = (winner.periodCount == null ? 0 : winner.periodCount) + 1;
        winner.picksThisCall++;
        winner.dirty = true;
        // Charge the pick against the load metrics so the next request in this same batch
        // sees the winner as busier. The counted records do not exist until commit, so
        // without this a bulk insert would hand every record to the same member.
        winner.chargeOnePick(groupState.capacityQueries);

        if (winningTier != null && winningTier > firstTier(groupState)) {
            notes.add('Filled from tier ' + winningTier + '; no one on an earlier tier was available.');
        }

        WSM_RRResult result = new WSM_RRResult(true, WSM_RRResult.STATUS_ASSIGNED, gid);
        result.userId = winner.record.WSM_User__c;
        result.memberId = winner.record.Id;
        finalize(i, result, WSM_AssignmentLogger.buildLog(gid, winner.record.Id, winner.record.WSM_User__c,
            groupRecord.WSM_Algorithm__c, WSM_AssignmentLogger.LOG_STATUS_ASSIGNED, req,
            notes.isEmpty() ? null : String.join(notes, ' ')));
    }

    private static Integer firstTier(WSM_GroupState groupState) {
        List<Integer> tiers = groupState.tiers;
        return tiers.isEmpty() ? 1 : tiers[0];
    }

    private static String joinDetail(String skipSummary, List<String> notes) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(skipSummary)) {
            parts.add(skipSummary);
        }
        if (notes != null && !notes.isEmpty()) {
            parts.add(String.join(notes, ' '));
        }
        return parts.isEmpty() ? null : String.join(parts, '. ');
    }

    /** Start of the current Daily/Weekly(Monday)/Monthly(1st) window, midnight in the org's default time zone. */
    @TestVisible
    private static Datetime periodStartFor(String period) {
        Date today = Date.today();
        Date windowStart;
        if (period == 'Weekly') {
            windowStart = mostRecentMonday(today);
        } else if (period == 'Monthly') {
            windowStart = Date.newInstance(today.year(), today.month(), 1);
        } else {
            windowStart = today;
        }
        return Datetime.newInstance(windowStart, Time.newInstance(0, 0, 0, 0));
    }

    private static Date mostRecentMonday(Date today) {
        Date epochThursday = Date.newInstance(1970, 1, 1);
        Integer dowFromThursday = Math.mod(epochThursday.daysBetween(today), 7);
        Integer daysSinceMonday = Math.mod(dowFromThursday + 3, 7);
        return today.addDays(-daysSinceMonday);
    }

    private static WSM_RRResult errorResult(String status, Id groupId, String message) {
        WSM_RRResult result = new WSM_RRResult(false, status, groupId);
        result.message = message;
        return result;
    }
}
