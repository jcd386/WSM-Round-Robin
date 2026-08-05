/**
 * WSM_RR_AdminController
 *
 * Apex controller surface for the WSM Round Robin Manager admin app (wsmRr* LWCs).
 * Every method is @AuraEnabled and non-cacheable — this is an admin tool, not a
 * high-traffic read surface, and callers always want the freshest state after a
 * mutation. Assignment decisions themselves are delegated to WSM_RoundRobinService
 * (assign/preview); this class never implements selection logic, only CRUD +
 * read-model shaping for the UI and a thin wrapper around the Simulator.
 */
public with sharing class WSM_RR_AdminController {

    private static final Integer DEFAULT_RECENT_LOG_LIMIT = 25;
    private static final Integer MAX_RECENT_LOG_LIMIT = 200;
    private static final Integer SORT_ORDER_INCREMENT = 10;

    // ------------------------------------------------------------------
    // Wire DTOs
    // ------------------------------------------------------------------

    public class GroupSummary {
        @AuraEnabled public Id groupId;
        @AuraEnabled public String name;
        @AuraEnabled public String developerName;
        @AuraEnabled public String algorithm;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Integer memberCount;
        @AuraEnabled public Integer assignments30d;
    }

    public class GroupDetail {
        @AuraEnabled public GroupInfo grp;
        @AuraEnabled public List<MemberRow> members;
        @AuraEnabled public List<LogEntry> recentLogs;
        @AuraEnabled public String periodLabel;
        @AuraEnabled public Datetime periodStart;
        @AuraEnabled public Boolean hasAnyLog;
    }

    public class GroupInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String developerName;
        @AuraEnabled public Boolean active;
        @AuraEnabled public String algorithm;
        @AuraEnabled public String capacityMode;
        @AuraEnabled public String period;
        @AuraEnabled public Integer defaultMemberCap;
        @AuraEnabled public Id fallbackUserId;
        @AuraEnabled public String fallbackUserName;
        @AuraEnabled public String fallbackQueueId;
        @AuraEnabled public String fallbackQueueName;
        @AuraEnabled public String calibration;
        @AuraEnabled public String description;
    }

    public class MemberRow {
        @AuraEnabled public Id memberId;
        @AuraEnabled public Id userId;
        @AuraEnabled public String userName;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Integer weight;
        @AuraEnabled public Integer capOverride;
        @AuraEnabled public Integer effectiveCap;
        @AuraEnabled public Integer periodCount;
        @AuraEnabled public Date oooStart;
        @AuraEnabled public Date oooReturn;
        @AuraEnabled public Datetime lastAssigned;
        @AuraEnabled public Integer totalAssignments;
        @AuraEnabled public Integer sortOrder;
        @AuraEnabled public Boolean isManager;
    }

    public class LogEntry {
        @AuraEnabled public Id logId;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public Id assignedUserId;
        @AuraEnabled public String assignedUserName;
        @AuraEnabled public String memberUserName;
        @AuraEnabled public Datetime timestampValue;
        @AuraEnabled public String context;
        @AuraEnabled public String assignedRecordId;
        @AuraEnabled public String detail;
    }

    public class FallbackOption {
        @AuraEnabled public String targetId;
        @AuraEnabled public String name;
        @AuraEnabled public String targetType;
    }

    public class UserOption {
        @AuraEnabled public Id userId;
        @AuraEnabled public String name;
        @AuraEnabled public String username;
    }

    public class SimulationResult {
        @AuraEnabled public String status;
        @AuraEnabled public Id wouldAssignUserId;
        @AuraEnabled public String wouldAssignUserName;
        @AuraEnabled public Boolean committed;
        @AuraEnabled public Id logId;
        @AuraEnabled public List<Verdict> verdicts;
    }

    public class Verdict {
        @AuraEnabled public Id memberId;
        @AuraEnabled public String userName;
        @AuraEnabled public Boolean eligible;
        @AuraEnabled public String skipReason;
    }

    // Shape of the JSON payload accepted by saveGroup(). Not @AuraEnabled — this
    // class is only ever built by JSON.deserialize() from the LWC's request body,
    // never sent back to the client.
    private class SaveGroupInput {
        public Id id;
        public String name;
        public String developerName;
        public String algorithm;
        public String capacityMode;
        public String period;
        public Integer defaultMemberCap;
        public Id fallbackUserId;
        public String fallbackQueueId;
        public String calibration;
        public String description;
        public Boolean active;
    }

    // ------------------------------------------------------------------
    // Group list + detail
    // ------------------------------------------------------------------

    @AuraEnabled
    public static List<GroupSummary> getGroups() {
        try {
            Map<Id, Integer> memberCounts = new Map<Id, Integer>();
            for (AggregateResult ar : [
                SELECT WSM_Group__c grp, COUNT(Id) cnt
                FROM WSM_Round_Robin_Member__c
                GROUP BY WSM_Group__c
            ]) {
                Id grpId = (Id) ar.get('grp');
                if (grpId != null) {
                    memberCounts.put(grpId, (Integer) ar.get('cnt'));
                }
            }

            Map<Id, Integer> assignments30dByGroup = new Map<Id, Integer>();
            for (AggregateResult ar : [
                SELECT WSM_Group__c grp, COUNT(Id) cnt
                FROM WSM_Assignment_Log__c
                WHERE WSM_Status__c = 'Assigned' AND CreatedDate = LAST_N_DAYS:30
                GROUP BY WSM_Group__c
            ]) {
                Id grpId = (Id) ar.get('grp');
                if (grpId != null) {
                    assignments30dByGroup.put(grpId, (Integer) ar.get('cnt'));
                }
            }

            List<GroupSummary> results = new List<GroupSummary>();
            for (WSM_Round_Robin_Group__c g : [
                SELECT Id, Name, WSM_Developer_Name__c, WSM_Algorithm__c, WSM_Active__c
                FROM WSM_Round_Robin_Group__c
                ORDER BY Name ASC
            ]) {
                GroupSummary summary = new GroupSummary();
                summary.groupId = g.Id;
                summary.name = g.Name;
                summary.developerName = g.WSM_Developer_Name__c;
                summary.algorithm = g.WSM_Algorithm__c;
                summary.active = g.WSM_Active__c;
                summary.memberCount = memberCounts.containsKey(g.Id) ? memberCounts.get(g.Id) : 0;
                summary.assignments30d = assignments30dByGroup.containsKey(g.Id) ? assignments30dByGroup.get(g.Id) : 0;
                results.add(summary);
            }
            return results;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    @AuraEnabled
    public static GroupDetail getGroupDetail(Id groupId) {
        try {
            List<WSM_Round_Robin_Group__c> groups = [
                SELECT Id, Name, WSM_Developer_Name__c, WSM_Active__c, WSM_Algorithm__c,
                       WSM_Capacity_Mode__c, WSM_Period__c, WSM_Default_Member_Cap__c,
                       WSM_Fallback_User__c, WSM_Fallback_User__r.Name, WSM_Fallback_Queue_Id__c, WSM_Calibration__c,
                       WSM_Description__c
                FROM WSM_Round_Robin_Group__c
                WHERE Id = :groupId
                LIMIT 1
            ];
            if (groups.isEmpty()) {
                throw friendlyError('Round Robin group not found.');
            }
            WSM_Round_Robin_Group__c g = groups[0];

            String period = String.isBlank(g.WSM_Period__c) ? 'Daily' : g.WSM_Period__c;
            Datetime periodStart = computePeriodStart(period);

            Map<Id, Integer> periodCountsByMember = new Map<Id, Integer>();
            for (AggregateResult ar : [
                SELECT WSM_Member__c memberId, COUNT(Id) cnt
                FROM WSM_Assignment_Log__c
                WHERE WSM_Group__c = :groupId AND WSM_Status__c = 'Assigned' AND CreatedDate >= :periodStart
                GROUP BY WSM_Member__c
            ]) {
                Id memberId = (Id) ar.get('memberId');
                if (memberId != null) {
                    periodCountsByMember.put(memberId, (Integer) ar.get('cnt'));
                }
            }

            List<MemberRow> memberRows = new List<MemberRow>();
            for (WSM_Round_Robin_Member__c m : [
                SELECT Id, WSM_User__c, WSM_User__r.Name, WSM_Active__c, WSM_Weight__c,
                       WSM_Cap_Override__c, WSM_OOO_Start_Date__c, WSM_OOO_Return_Date__c,
                       WSM_Last_Assigned__c, WSM_Total_Assignments__c, WSM_Sort_Order__c,
                       WSM_Is_Manager__c
                FROM WSM_Round_Robin_Member__c
                WHERE WSM_Group__c = :groupId
                ORDER BY WSM_Sort_Order__c ASC NULLS LAST, Id ASC
            ]) {
                MemberRow row = new MemberRow();
                row.memberId = m.Id;
                row.userId = m.WSM_User__c;
                row.userName = m.WSM_User__c != null ? m.WSM_User__r.Name : null;
                row.active = m.WSM_Active__c;
                row.weight = m.WSM_Weight__c != null ? m.WSM_Weight__c.intValue() : null;
                row.capOverride = m.WSM_Cap_Override__c != null ? m.WSM_Cap_Override__c.intValue() : null;
                row.effectiveCap = computeEffectiveCap(m.WSM_Cap_Override__c, g.WSM_Default_Member_Cap__c);
                row.periodCount = periodCountsByMember.containsKey(m.Id) ? periodCountsByMember.get(m.Id) : 0;
                row.oooStart = m.WSM_OOO_Start_Date__c;
                row.oooReturn = m.WSM_OOO_Return_Date__c;
                row.lastAssigned = m.WSM_Last_Assigned__c;
                row.totalAssignments = m.WSM_Total_Assignments__c != null ? m.WSM_Total_Assignments__c.intValue() : 0;
                row.sortOrder = m.WSM_Sort_Order__c != null ? m.WSM_Sort_Order__c.intValue() : null;
                row.isManager = m.WSM_Is_Manager__c;
                memberRows.add(row);
            }

            List<LogEntry> recentLogs = queryRecentLogs(groupId, DEFAULT_RECENT_LOG_LIMIT);

            GroupInfo info = new GroupInfo();
            info.id = g.Id;
            info.name = g.Name;
            info.developerName = g.WSM_Developer_Name__c;
            info.active = g.WSM_Active__c;
            info.algorithm = g.WSM_Algorithm__c;
            info.capacityMode = g.WSM_Capacity_Mode__c;
            info.period = g.WSM_Period__c;
            info.defaultMemberCap = g.WSM_Default_Member_Cap__c != null ? g.WSM_Default_Member_Cap__c.intValue() : null;
            info.fallbackUserId = g.WSM_Fallback_User__c;
            info.fallbackUserName = g.WSM_Fallback_User__c != null ? g.WSM_Fallback_User__r.Name : null;
            info.fallbackQueueId = g.WSM_Fallback_Queue_Id__c;
            if (String.isNotBlank(g.WSM_Fallback_Queue_Id__c)) {
                List<Group> queues = [SELECT Name FROM Group WHERE Id = :g.WSM_Fallback_Queue_Id__c LIMIT 1];
                info.fallbackQueueName = queues.isEmpty() ? null : queues[0].Name;
            }
            info.calibration = g.WSM_Calibration__c;
            info.description = g.WSM_Description__c;

            GroupDetail detail = new GroupDetail();
            detail.grp = info;
            detail.members = memberRows;
            detail.recentLogs = recentLogs;
            detail.periodLabel = period;
            detail.periodStart = periodStart;
            detail.hasAnyLog = !recentLogs.isEmpty();
            return detail;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // Group CRUD
    // ------------------------------------------------------------------

    @AuraEnabled
    public static Id saveGroup(String groupJson) {
        try {
            SaveGroupInput input = (SaveGroupInput) JSON.deserialize(groupJson, SaveGroupInput.class);

            if (String.isBlank(input.name)) {
                throw friendlyError('Group name is required.');
            }

            String developerName = String.isBlank(input.developerName)
                ? slugify(input.name)
                : slugify(input.developerName);

            if (String.isBlank(developerName)) {
                throw friendlyError('Could not derive a developer name from "' + input.name + '". Please provide one.');
            }

            List<WSM_Round_Robin_Group__c> duplicates = [
                SELECT Id
                FROM WSM_Round_Robin_Group__c
                WHERE WSM_Developer_Name__c = :developerName AND Id != :input.id
                LIMIT 1
            ];
            if (!duplicates.isEmpty()) {
                throw friendlyError(
                    'A group with developer name "' + developerName + '" already exists. Choose a different name.'
                );
            }

            WSM_Round_Robin_Group__c g = String.isNotBlank(input.id)
                ? new WSM_Round_Robin_Group__c(Id = input.id)
                : new WSM_Round_Robin_Group__c();
            g.Name = input.name;
            g.WSM_Developer_Name__c = developerName;
            g.WSM_Algorithm__c = input.algorithm;
            g.WSM_Capacity_Mode__c = input.capacityMode;
            g.WSM_Period__c = input.period;
            g.WSM_Default_Member_Cap__c = input.defaultMemberCap;
            g.WSM_Fallback_User__c = input.fallbackUserId;
            g.WSM_Fallback_Queue_Id__c = input.fallbackQueueId;
            g.WSM_Calibration__c = input.calibration;
            g.WSM_Description__c = input.description;
            g.WSM_Active__c = input.active == null ? true : input.active;

            if (String.isNotBlank(input.id)) {
                update g;
            } else {
                insert g;
            }
            return g.Id;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    @AuraEnabled
    public static void setGroupActive(Id groupId, Boolean active) {
        try {
            update new WSM_Round_Robin_Group__c(Id = groupId, WSM_Active__c = active);
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteGroup(Id groupId) {
        try {
            // Members are Master-Detail on the group and cascade-delete automatically.
            // Assignment logs use a Lookup with deleteConstraint=SetNull, so history survives.
            delete new WSM_Round_Robin_Group__c(Id = groupId);
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // Members
    // ------------------------------------------------------------------


    @AuraEnabled
    public static List<FallbackOption> searchFallbackTargets(String term) {
        try {
            List<FallbackOption> options = new List<FallbackOption>();
            String pattern = '%' + (term == null ? '' : String.escapeSingleQuotes(term)) + '%';
            List<User> users = String.isBlank(term)
                ? [SELECT Id, Name FROM User WHERE IsActive = true ORDER BY Name LIMIT 10]
                : [SELECT Id, Name FROM User WHERE IsActive = true AND Name LIKE :pattern ORDER BY Name LIMIT 10];
            for (User u : users) {
                FallbackOption o = new FallbackOption();
                o.targetId = u.Id;
                o.name = u.Name;
                o.targetType = 'User';
                options.add(o);
            }
            List<Group> queues = String.isBlank(term)
                ? [SELECT Id, Name FROM Group WHERE Type = 'Queue' ORDER BY Name LIMIT 10]
                : [SELECT Id, Name FROM Group WHERE Type = 'Queue' AND Name LIKE :pattern ORDER BY Name LIMIT 10];
            for (Group q : queues) {
                FallbackOption o = new FallbackOption();
                o.targetId = q.Id;
                o.name = q.Name;
                o.targetType = 'Queue';
                options.add(o);
            }
            return options;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    @AuraEnabled
    public static List<UserOption> searchUsers(String term, Id groupId) {
        try {
            Set<Id> existingUserIds = new Set<Id>();
            if (groupId != null) {
                for (WSM_Round_Robin_Member__c m : [
                    SELECT WSM_User__c
                    FROM WSM_Round_Robin_Member__c
                    WHERE WSM_Group__c = :groupId AND WSM_User__c != null
                ]) {
                    existingUserIds.add(m.WSM_User__c);
                }
            }

            List<User> users;
            if (String.isBlank(term)) {
                users = [
                    SELECT Id, Name, Username
                    FROM User
                    WHERE IsActive = true AND Id NOT IN :existingUserIds
                    ORDER BY Name ASC
                    LIMIT 20
                ];
            } else {
                String likeTerm = '%' + term + '%';
                users = [
                    SELECT Id, Name, Username
                    FROM User
                    WHERE IsActive = true AND Id NOT IN :existingUserIds AND Name LIKE :likeTerm
                    ORDER BY Name ASC
                    LIMIT 20
                ];
            }

            List<UserOption> options = new List<UserOption>();
            for (User u : users) {
                UserOption opt = new UserOption();
                opt.userId = u.Id;
                opt.name = u.Name;
                opt.username = u.Username;
                options.add(opt);
            }
            return options;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Id> addMembers(Id groupId, List<Id> userIds) {
        try {
            if (userIds == null || userIds.isEmpty()) {
                return new List<Id>();
            }

            Integer nextSortOrder = SORT_ORDER_INCREMENT;
            List<AggregateResult> maxOrderResult = [
                SELECT MAX(WSM_Sort_Order__c) maxOrder
                FROM WSM_Round_Robin_Member__c
                WHERE WSM_Group__c = :groupId
            ];
            if (!maxOrderResult.isEmpty() && maxOrderResult[0].get('maxOrder') != null) {
                Decimal maxOrder = (Decimal) maxOrderResult[0].get('maxOrder');
                nextSortOrder = maxOrder.intValue() + SORT_ORDER_INCREMENT;
            }

            List<WSM_Round_Robin_Member__c> toInsert = new List<WSM_Round_Robin_Member__c>();
            for (Id userId : userIds) {
                toInsert.add(new WSM_Round_Robin_Member__c(
                    WSM_Group__c = groupId,
                    WSM_User__c = userId,
                    WSM_Active__c = true,
                    WSM_Weight__c = 1,
                    WSM_Sort_Order__c = nextSortOrder
                ));
                nextSortOrder += SORT_ORDER_INCREMENT;
            }
            insert toInsert;

            List<Id> newIds = new List<Id>();
            for (WSM_Round_Robin_Member__c m : toInsert) {
                newIds.add(m.Id);
            }
            return newIds;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    @AuraEnabled
    public static void updateMembers(String membersJson) {
        try {
            List<Object> rawEntries = (List<Object>) JSON.deserializeUntyped(membersJson);
            List<WSM_Round_Robin_Member__c> toUpdate = new List<WSM_Round_Robin_Member__c>();

            for (Object rawEntry : rawEntries) {
                Map<String, Object> entry = (Map<String, Object>) rawEntry;

                if (!entry.containsKey('memberId') || entry.get('memberId') == null) {
                    throw friendlyError('Every member update requires a memberId.');
                }
                Id memberId = Id.valueOf(String.valueOf(entry.get('memberId')));

                WSM_Round_Robin_Member__c m = new WSM_Round_Robin_Member__c(Id = memberId);
                Boolean touched = false;

                if (entry.containsKey('active')) {
                    m.WSM_Active__c = (Boolean) entry.get('active');
                    touched = true;
                }
                if (entry.containsKey('weight')) {
                    m.WSM_Weight__c = toDecimal(entry.get('weight'));
                    touched = true;
                }
                if (entry.containsKey('capOverride')) {
                    m.WSM_Cap_Override__c = toDecimal(entry.get('capOverride'));
                    touched = true;
                }
                if (entry.containsKey('oooStart')) {
                    m.WSM_OOO_Start_Date__c = toDate(entry.get('oooStart'));
                    touched = true;
                }
                if (entry.containsKey('oooReturn')) {
                    m.WSM_OOO_Return_Date__c = toDate(entry.get('oooReturn'));
                    touched = true;
                }
                if (entry.containsKey('isManager')) {
                    m.WSM_Is_Manager__c = (Boolean) entry.get('isManager');
                    touched = true;
                }

                if (touched) {
                    toUpdate.add(m);
                }
            }

            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    @AuraEnabled
    public static void removeMember(Id memberId) {
        try {
            delete new WSM_Round_Robin_Member__c(Id = memberId);
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    @AuraEnabled
    public static void reorderMembers(Id groupId, List<Id> orderedMemberIds) {
        try {
            if (orderedMemberIds == null || orderedMemberIds.isEmpty()) {
                return;
            }

            Set<Id> memberIdsInGroup = new Map<Id, WSM_Round_Robin_Member__c>([
                SELECT Id FROM WSM_Round_Robin_Member__c WHERE WSM_Group__c = :groupId
            ]).keySet();

            Integer order = SORT_ORDER_INCREMENT;
            List<WSM_Round_Robin_Member__c> toUpdate = new List<WSM_Round_Robin_Member__c>();
            for (Id memberId : orderedMemberIds) {
                if (!memberIdsInGroup.contains(memberId)) {
                    throw friendlyError('Member ' + memberId + ' does not belong to this group.');
                }
                toUpdate.add(new WSM_Round_Robin_Member__c(Id = memberId, WSM_Sort_Order__c = order));
                order += SORT_ORDER_INCREMENT;
            }
            update toUpdate;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    @AuraEnabled
    public static void resetCounters(Id groupId) {
        try {
            List<WSM_Round_Robin_Member__c> members = [
                SELECT Id, WSM_Rotation_Value__c, WSM_Last_Assigned__c
                FROM WSM_Round_Robin_Member__c
                WHERE WSM_Group__c = :groupId
            ];
            for (WSM_Round_Robin_Member__c m : members) {
                m.WSM_Rotation_Value__c = null;
                m.WSM_Last_Assigned__c = null;
            }
            if (!members.isEmpty()) {
                update members;
            }
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // Activity
    // ------------------------------------------------------------------

    @AuraEnabled
    public static List<LogEntry> getRecentAssignments(Id groupId, Integer limitN) {
        try {
            Integer effectiveLimit = (limitN == null || limitN <= 0) ? DEFAULT_RECENT_LOG_LIMIT : limitN;
            effectiveLimit = Math.min(effectiveLimit, MAX_RECENT_LOG_LIMIT);
            return queryRecentLogs(groupId, effectiveLimit);
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // Simulator
    // ------------------------------------------------------------------

    @AuraEnabled
    public static SimulationResult simulate(Id groupId, Boolean commitAssignment) {
        try {
            Boolean doCommit = commitAssignment == true;

            WSM_RRPreview preview = WSM_RoundRobinService.preview(groupId);

            SimulationResult result = new SimulationResult();
            result.verdicts = buildVerdicts(preview);
            result.committed = doCommit;

            if (doCommit) {
                WSM_RRResult assignResult = WSM_RoundRobinService.assign(groupId);
                result.status = assignResult.status;
                result.wouldAssignUserId = assignResult.userId;
                result.wouldAssignUserName = resolveUserName(assignResult.userId);
                result.logId = assignResult.logId;
            } else {
                // WSM_RRPreview has no status field — it only reports whether a member
                // would be picked (wouldAssignUserId set) or the pool is effectively
                // empty (null), which also covers group-not-found/inactive. The full
                // GROUP_NOT_FOUND/GROUP_INACTIVE/FALLBACK/etc. taxonomy is only
                // available from the committed assign() call.
                result.status = preview.wouldAssignUserId != null ? 'ASSIGNED' : 'NO_ELIGIBLE_MEMBERS';
                result.wouldAssignUserId = preview.wouldAssignUserId;
                result.wouldAssignUserName = resolveUserName(preview.wouldAssignUserId);
                result.logId = null;
            }

            return result;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    private static List<Verdict> buildVerdicts(WSM_RRPreview preview) {
        List<Verdict> verdicts = new List<Verdict>();
        if (preview == null || preview.verdicts == null) {
            return verdicts;
        }
        for (WSM_RRPreview.MemberVerdict state : preview.verdicts) {
            Verdict v = new Verdict();
            v.memberId = state.memberId;
            v.userName = state.userName;
            v.eligible = state.eligible;
            v.skipReason = state.skipReason;
            verdicts.add(v);
        }
        return verdicts;
    }

    private static String resolveUserName(Id userId) {
        if (userId == null) {
            return null;
        }
        List<User> users = [SELECT Name FROM User WHERE Id = :userId LIMIT 1];
        return users.isEmpty() ? null : users[0].Name;
    }

    // ------------------------------------------------------------------
    // Private helpers
    // ------------------------------------------------------------------

    private static List<LogEntry> queryRecentLogs(Id groupId, Integer limitN) {
        List<LogEntry> entries = new List<LogEntry>();
        for (WSM_Assignment_Log__c log : [
            SELECT Id, Name, WSM_Status__c, WSM_Assigned_User__c, WSM_Assigned_User__r.Name,
                   WSM_Member__c, WSM_Member__r.WSM_User__r.Name, CreatedDate, WSM_Context__c,
                   WSM_Assigned_Record_Id__c, WSM_Detail__c
            FROM WSM_Assignment_Log__c
            WHERE WSM_Group__c = :groupId
            ORDER BY CreatedDate DESC
            LIMIT :limitN
        ]) {
            LogEntry entry = new LogEntry();
            entry.logId = log.Id;
            entry.name = log.Name;
            entry.status = log.WSM_Status__c;
            entry.assignedUserId = log.WSM_Assigned_User__c;
            entry.assignedUserName = log.WSM_Assigned_User__c != null ? log.WSM_Assigned_User__r.Name : null;
            entry.memberUserName = (log.WSM_Member__c != null && log.WSM_Member__r != null && log.WSM_Member__r.WSM_User__r != null)
                ? log.WSM_Member__r.WSM_User__r.Name
                : null;
            entry.timestampValue = log.CreatedDate;
            entry.context = log.WSM_Context__c;
            entry.assignedRecordId = log.WSM_Assigned_Record_Id__c;
            entry.detail = log.WSM_Detail__c;
            entries.add(entry);
        }
        return entries;
    }

    private static Integer computeEffectiveCap(Decimal capOverride, Decimal defaultMemberCap) {
        Decimal effective = capOverride != null ? capOverride : defaultMemberCap;
        return effective != null ? effective.intValue() : null;
    }

    /**
     * Reproduces the engine's period-window logic for display purposes:
     * Daily = today, Weekly = most recent Monday (locale-independent), Monthly = the 1st.
     * 1900-01-01 was a Monday, so days-since-then mod 7 gives a stable offset back to
     * the current week's Monday without depending on Date.toStartOfWeek()'s locale behavior.
     */
    private static Datetime computePeriodStart(String period) {
        Date today = Date.today();
        Date startDate;
        if (period == 'Weekly') {
            Integer offsetFromMonday = Math.mod(Date.newInstance(1900, 1, 1).daysBetween(today), 7);
            startDate = today.addDays(-offsetFromMonday);
        } else if (period == 'Monthly') {
            startDate = Date.newInstance(today.year(), today.month(), 1);
        } else {
            startDate = today;
        }
        return Datetime.newInstance(startDate, Time.newInstance(0, 0, 0, 0));
    }

    private static String slugify(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String slug = value.trim().toLowerCase();
        slug = slug.replaceAll('[^a-z0-9]+', '_');
        slug = slug.replaceAll('^_+|_+$', '');
        return String.isBlank(slug) ? null : slug;
    }

    private static Decimal toDecimal(Object value) {
        if (value == null) {
            return null;
        }
        return Decimal.valueOf(String.valueOf(value));
    }

    private static Date toDate(Object value) {
        if (value == null) {
            return null;
        }
        return Date.valueOf(String.valueOf(value));
    }

    /** AuraHandledException swallows its constructor message in Apex context; setMessage keeps it readable for the LWC and tests. */
    private static AuraHandledException friendlyError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
