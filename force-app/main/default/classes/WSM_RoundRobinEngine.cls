/**
 * Runs without sharing because it's invoked from Flow/Process/Invocable contexts that
 * can execute as guest users, community users, or automation service accounts with no
 * access of their own to the WSM_ objects (e.g. a public Web-to-Case flow routing a new
 * Case needs to read the group/member config and write the winning member + a log row,
 * even though the guest running user has no direct sharing on WSM_Round_Robin_Group__c).
 * The elevated access is scoped tightly: this class only ever reads its own
 * WSM_Round_Robin_Group__c / WSM_Round_Robin_Member__c / WSM_Assignment_Log__c objects
 * and never touches the caller's business data. The caller-facing entry points
 * (WSM_RoundRobinService, WSM_RoundRobinInvocable) stay `with sharing` so record-level
 * authorization is still enforced everywhere this class doesn't own.
 *
 * Fixed query/DML footprint per assign() call regardless of batch size: resolve (0-1) +
 * lock (1-2, with retry) + members (0-1) + period aggregates (0-3) queries, and at most
 * one member update + one log insert.
 */
public without sharing class WSM_RoundRobinEngine {

    @TestVisible
    private WSM_RoundRobinSelector selector = new WSM_RoundRobinSelector();

    private List<WSM_RRResult> results;
    private List<WSM_Assignment_Log__c> logsToInsert;
    private List<WSM_RRResult> resultsByLogIndex;

    public List<WSM_RRResult> assign(List<WSM_RRRequest> requests) {
        results = new List<WSM_RRResult>();
        logsToInsert = new List<WSM_Assignment_Log__c>();
        resultsByLogIndex = new List<WSM_RRResult>();

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
     * Dry run for one grp: no lock, no DML. Uses the same eligibility pipeline and
     * strategy ranking as assign() so the preview matches what a real call would do.
     */
    public WSM_RRPreview preview(Id groupId) {
        WSM_RRPreview preview = new WSM_RRPreview();
        preview.groupId = groupId;
        if (groupId == null) {
            return preview;
        }

        List<WSM_Round_Robin_Group__c> groups = selector.queryGroups(new Set<Id>{ groupId });
        if (groups.isEmpty()) {
            return preview;
        }
        WSM_Round_Robin_Group__c groupRecord = groups[0];

        WSM_GroupState groupState = new WSM_GroupState(groupRecord);
        for (WSM_Round_Robin_Member__c mr : selector.membersForGroups(new Set<Id>{ groupId })) {
            groupState.members.add(new WSM_MemberState(mr));
        }
        applyPeriodCounts(new Map<Id, WSM_GroupState>{ groupId => groupState });

        WSM_EligibilityPipeline pipeline = WSM_EligibilityPipeline.defaultPipeline();
        Date today = Date.today();

        List<WSM_MemberState> eligible = new List<WSM_MemberState>();
        Map<Id, String> reasonByMember = new Map<Id, String>();
        for (WSM_MemberState ms : groupState.members) {
            String reason = pipeline.evaluate(ms, groupState, today);
            if (reason == null) {
                eligible.add(ms);
            } else {
                reasonByMember.put(ms.record.Id, reason);
            }
        }

        List<String> warnings = new List<String>();
        WSM_ISelectionStrategy strategy = WSM_StrategyFactory.create(groupRecord.WSM_Algorithm__c, groupRecord.WSM_Calibration__c, warnings);
        List<WSM_MemberState> rankedEligible = strategy.sortMembers(eligible);

        Map<Id, Integer> rankByMember = new Map<Id, Integer>();
        for (Integer i = 0; i < rankedEligible.size(); i++) {
            rankByMember.put(rankedEligible[i].record.Id, i + 1);
        }

        if (!rankedEligible.isEmpty() && groupRecord.WSM_Active__c == true) {
            WSM_MemberState winner = rankedEligible[0];
            preview.wouldAssignMemberId = winner.record.Id;
            preview.wouldAssignUserId = winner.record.WSM_User__c;
        }

        for (WSM_MemberState ms : groupState.members) {
            WSM_RRPreview.MemberVerdict verdict = new WSM_RRPreview.MemberVerdict();
            verdict.memberId = ms.record.Id;
            verdict.userId = ms.record.WSM_User__c;
            verdict.userName = ms.record.WSM_User__r != null ? ms.record.WSM_User__r.Name : null;
            Boolean isEligible = !reasonByMember.containsKey(ms.record.Id);
            verdict.eligible = isEligible;
            verdict.skipReason = isEligible ? '' : reasonByMember.get(ms.record.Id);
            verdict.sortRank = rankByMember.get(ms.record.Id);
            preview.verdicts.add(verdict);
        }
        return preview;
    }

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

        List<WSM_MemberState> eligible = new List<WSM_MemberState>();
        Map<Id, String> skipReasonByMember = new Map<Id, String>();
        for (WSM_MemberState ms : groupState.members) {
            String reason = pipeline.evaluate(ms, groupState, today);
            if (reason == null) {
                eligible.add(ms);
            } else {
                skipReasonByMember.put(ms.record.Id, reason);
            }
        }

        if (eligible.isEmpty()) {
            String skipSummary = WSM_AssignmentLogger.buildSkipSummary(skipReasonByMember);
            if (groupRecord.WSM_Fallback_User__c != null) {
                WSM_RRResult result = new WSM_RRResult(true, WSM_RRResult.STATUS_FALLBACK, gid);
                result.userId = groupRecord.WSM_Fallback_User__c;
                result.message = 'No eligible members; routed to the fallback user.';
                finalize(i, result, WSM_AssignmentLogger.buildLog(gid, null, groupRecord.WSM_Fallback_User__c,
                    groupRecord.WSM_Algorithm__c, WSM_AssignmentLogger.LOG_STATUS_FALLBACK, req, skipSummary));
            } else if (String.isNotBlank(groupRecord.WSM_Fallback_Queue_Id__c)) {
                WSM_RRResult result = new WSM_RRResult(true, WSM_RRResult.STATUS_FALLBACK, gid);
                result.queueId = groupRecord.WSM_Fallback_Queue_Id__c;
                result.message = 'No eligible members; routed to the fallback queue.';
                String queueDetail = 'Routed to fallback queue ' + groupRecord.WSM_Fallback_Queue_Id__c
                    + (skipSummary == null ? '' : '. ' + skipSummary);
                finalize(i, result, WSM_AssignmentLogger.buildLog(gid, null, null,
                    groupRecord.WSM_Algorithm__c, WSM_AssignmentLogger.LOG_STATUS_FALLBACK, req, queueDetail));
            } else {
                WSM_RRResult result = errorResult(WSM_RRResult.STATUS_NO_ELIGIBLE_MEMBERS, gid,
                    'No eligible members and no fallback user configured.');
                finalize(i, result, WSM_AssignmentLogger.buildLog(gid, null, null, groupRecord.WSM_Algorithm__c,
                    WSM_AssignmentLogger.LOG_STATUS_NO_ELIGIBLE_MEMBERS, req, skipSummary));
            }
            return;
        }

        List<String> warnings = new List<String>();
        WSM_ISelectionStrategy strategy = WSM_StrategyFactory.create(groupRecord.WSM_Algorithm__c, groupRecord.WSM_Calibration__c, warnings);
        WSM_MemberState winner = strategy.selectNext(eligible);

        // Replayable stamping: all picks in this group during this call share txnBase but
        // get a strictly increasing one-SECOND offset. Whole seconds, not milliseconds:
        // Salesforce truncates milliseconds when persisting Datetime fields, which would
        // collapse a bulk batch's stamps into ties and lose the rotation order on replay.
        winner.lastAssigned = Datetime.newInstance(txnBase.getTime() + (groupState.msSequence * 1000));
        groupState.msSequence++;
        winner.periodCount = (winner.periodCount == null ? 0 : winner.periodCount) + 1;
        winner.picksThisCall++;
        winner.dirty = true;

        WSM_RRResult result = new WSM_RRResult(true, WSM_RRResult.STATUS_ASSIGNED, gid);
        result.userId = winner.record.WSM_User__c;
        result.memberId = winner.record.Id;
        finalize(i, result, WSM_AssignmentLogger.buildLog(gid, winner.record.Id, winner.record.WSM_User__c,
            groupRecord.WSM_Algorithm__c, WSM_AssignmentLogger.LOG_STATUS_ASSIGNED, req,
            warnings.isEmpty() ? null : String.join(warnings, ' ')));
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
