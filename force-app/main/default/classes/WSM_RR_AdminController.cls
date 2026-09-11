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
        @AuraEnabled public Integer tier;
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
        /** Configuration problems the admin should fix, e.g. a capacity query that will not compile. */
        @AuraEnabled public List<String> warnings;
        /** Which tier the pick came from, so the simulator can say "filled from the bench". */
        @AuraEnabled public Integer assignedFromTier;
    }

    public class Verdict {
        @AuraEnabled public Id memberId;
        @AuraEnabled public String userName;
        @AuraEnabled public Boolean eligible;
        @AuraEnabled public String skipReason;
        @AuraEnabled public Integer tier;
        @AuraEnabled public Boolean tierReached;
        @AuraEnabled public Decimal externalLoad;
        @AuraEnabled public List<CapacityReadingRow> capacity;
    }

    /** One Capacity Query's current reading for one member, as shown in the simulator. */
    public class CapacityReadingRow {
        @AuraEnabled public Id capacityQueryId;
        @AuraEnabled public String label;
        @AuraEnabled public Integer count;
        @AuraEnabled public Integer cap;
        @AuraEnabled public Boolean isCap;
        @AuraEnabled public Boolean isLoadMetric;
        @AuraEnabled public Boolean atCap;
        @AuraEnabled public String unavailableReason;
    }

    /** A Capacity Query and its filters, for the admin editor. */
    public class CapacityQueryRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String label;
        @AuraEnabled public String objectName;
        @AuraEnabled public String ownerField;
        @AuraEnabled public String role;
        @AuraEnabled public Integer cap;
        @AuraEnabled public Decimal loadWeight;
        @AuraEnabled public String filterLogic;
        @AuraEnabled public Boolean active;
        @AuraEnabled public Integer sortOrder;
        @AuraEnabled public String description;
        @AuraEnabled public List<CapacityFilterRow> filters;
        /** Compiler verdict, so the editor can show a problem before anything is routed. */
        @AuraEnabled public Boolean valid;
        @AuraEnabled public String invalidReason;
    }

    public class CapacityFilterRow {
        @AuraEnabled public Id id;
        @AuraEnabled public Integer filterNumber;
        @AuraEnabled public String fieldName;
        @AuraEnabled public String operator;
        @AuraEnabled public String valueSource;
        @AuraEnabled public String value;
        @AuraEnabled public String routedRecordField;
    }

    public class ObjectOption {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
    }

    public class FieldOption {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String fieldType;
        @AuraEnabled public Boolean groupable;
        /** Picklist values, so the editor can offer them instead of free text. */
        @AuraEnabled public List<String> picklistValues;
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
                       WSM_Is_Manager__c, WSM_Tier__c
                FROM WSM_Round_Robin_Member__c
                WHERE WSM_Group__c = :groupId
                ORDER BY WSM_Tier__c ASC NULLS FIRST, WSM_Sort_Order__c ASC NULLS LAST, Id ASC
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
                row.tier = m.WSM_Tier__c != null ? m.WSM_Tier__c.intValue() : 1;
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
                if (entry.containsKey('tier')) {
                    m.WSM_Tier__c = toDecimal(entry.get('tier'));
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
            result.warnings = preview.warnings == null ? new List<String>() : preview.warnings;
            result.assignedFromTier = preview.assignedFromTier;

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
            v.tier = state.tier;
            v.tierReached = state.tierReached;
            v.externalLoad = state.externalLoad;
            v.capacity = new List<CapacityReadingRow>();
            if (state.capacity != null) {
                for (WSM_RRPreview.CapacityReading reading : state.capacity) {
                    CapacityReadingRow row = new CapacityReadingRow();
                    row.capacityQueryId = reading.capacityQueryId;
                    row.label = reading.label;
                    row.count = reading.count;
                    row.cap = reading.cap;
                    row.isCap = reading.isCap;
                    row.isLoadMetric = reading.isLoadMetric;
                    row.atCap = reading.atCap;
                    row.unavailableReason = reading.unavailableReason;
                    v.capacity.add(row);
                }
            }
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
    // Capacity Queries
    // ------------------------------------------------------------------

    /**
     * Every capacity query on the group, active or not, each carrying the compiler's
     * verdict so the editor can show a problem before anything gets routed with it.
     */
    @AuraEnabled
    public static List<CapacityQueryRow> getCapacityQueries(Id groupId) {
        try {
            List<CapacityQueryRow> rows = new List<CapacityQueryRow>();
            for (WSM_Capacity_Query__c config : [
                SELECT Id, Name, WSM_Label__c, WSM_Object__c, WSM_Owner_Field__c, WSM_Role__c,
                       WSM_Cap__c, WSM_Load_Weight__c, WSM_Filter_Logic__c, WSM_Active__c,
                       WSM_Sort_Order__c, WSM_Description__c,
                       (SELECT Id, WSM_Filter_Number__c, WSM_Field__c, WSM_Operator__c,
                               WSM_Value_Source__c, WSM_Value__c, WSM_Routed_Record_Field__c
                        FROM Filters__r ORDER BY WSM_Filter_Number__c)
                FROM WSM_Capacity_Query__c
                WHERE WSM_Group__c = :groupId
                ORDER BY WSM_Sort_Order__c ASC NULLS LAST, Id ASC
            ]) {
                rows.add(toCapacityQueryRow(config));
            }
            return rows;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    private static CapacityQueryRow toCapacityQueryRow(WSM_Capacity_Query__c config) {
        CapacityQueryRow row = new CapacityQueryRow();
        row.id = config.Id;
        row.name = config.Name;
        row.label = config.WSM_Label__c;
        row.objectName = config.WSM_Object__c;
        row.ownerField = config.WSM_Owner_Field__c;
        row.role = config.WSM_Role__c;
        row.cap = config.WSM_Cap__c != null ? config.WSM_Cap__c.intValue() : null;
        row.loadWeight = config.WSM_Load_Weight__c;
        row.filterLogic = config.WSM_Filter_Logic__c;
        row.active = config.WSM_Active__c;
        row.sortOrder = config.WSM_Sort_Order__c != null ? config.WSM_Sort_Order__c.intValue() : null;
        row.description = config.WSM_Description__c;
        row.filters = new List<CapacityFilterRow>();
        for (WSM_Capacity_Filter__c filter : config.Filters__r) {
            CapacityFilterRow f = new CapacityFilterRow();
            f.id = filter.Id;
            f.filterNumber = filter.WSM_Filter_Number__c != null ? filter.WSM_Filter_Number__c.intValue() : null;
            f.fieldName = filter.WSM_Field__c;
            f.operator = filter.WSM_Operator__c;
            f.valueSource = filter.WSM_Value_Source__c;
            f.value = filter.WSM_Value__c;
            f.routedRecordField = filter.WSM_Routed_Record_Field__c;
            row.filters.add(f);
        }
        WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(config, config.Filters__r);
        row.valid = def.isValid;
        row.invalidReason = def.invalidReason;
        return row;
    }

    /**
     * Compiles a capacity query without saving it, so the editor can tell the admin
     * whether it will work while they are still typing. Same compiler the engine uses,
     * so a pass here means a pass at runtime.
     */
    @AuraEnabled
    public static CapacityQueryRow validateCapacityQuery(String capacityJson) {
        try {
            CapacityInput input = (CapacityInput) JSON.deserialize(capacityJson, CapacityInput.class);
            WSM_Capacity_Query__c config = new WSM_Capacity_Query__c(
                WSM_Label__c = input.label,
                WSM_Object__c = input.objectName,
                WSM_Owner_Field__c = input.ownerField,
                WSM_Role__c = input.role,
                WSM_Cap__c = input.cap,
                WSM_Load_Weight__c = input.loadWeight,
                WSM_Filter_Logic__c = input.filterLogic,
                WSM_Active__c = input.active == null ? true : input.active
            );
            List<WSM_Capacity_Filter__c> filters = buildFilterRecords(input, null);

            WSM_CapacityQueryDef def = WSM_CapacityQueryBuilder.compile(config, filters);
            CapacityQueryRow row = new CapacityQueryRow();
            row.label = input.label;
            row.objectName = input.objectName;
            row.valid = def.isValid;
            row.invalidReason = def.invalidReason;
            return row;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    /**
     * Upserts a capacity query and replaces its filters wholesale. Replacing rather than
     * diffing keeps Filter Numbers and Filter Logic consistent: a partial update could
     * leave logic pointing at a filter that no longer exists.
     */
    @AuraEnabled
    public static Id saveCapacityQuery(String capacityJson) {
        try {
            CapacityInput input = (CapacityInput) JSON.deserialize(capacityJson, CapacityInput.class);
            if (input.groupId == null) {
                throw friendlyError('A capacity query needs a group.');
            }
            if (String.isBlank(input.label)) {
                throw friendlyError('Give the count a short label. It shows up in skip reasons.');
            }

            WSM_Capacity_Query__c config = new WSM_Capacity_Query__c();
            if (input.id != null) {
                config.Id = input.id;
            } else {
                // Master-detail on this object is deliberately not reparentable, so the
                // group can only be written on insert. Setting it on an update throws
                // "Field is not writeable" even when the value has not changed.
                config.WSM_Group__c = input.groupId;
            }
            config.WSM_Label__c = input.label;
            config.WSM_Object__c = input.objectName;
            config.WSM_Owner_Field__c = input.ownerField;
            config.WSM_Role__c = String.isBlank(input.role) ? WSM_CapacityQueryDef.ROLE_CAP : input.role;
            config.WSM_Cap__c = input.cap;
            config.WSM_Load_Weight__c = input.loadWeight;
            config.WSM_Filter_Logic__c = input.filterLogic;
            config.WSM_Active__c = input.active == null ? true : input.active;
            config.WSM_Sort_Order__c = input.sortOrder;
            config.WSM_Description__c = input.description;
            upsert config;

            delete [SELECT Id FROM WSM_Capacity_Filter__c WHERE WSM_Capacity_Query__c = :config.Id];
            List<WSM_Capacity_Filter__c> filters = buildFilterRecords(input, config.Id);
            if (!filters.isEmpty()) {
                insert filters;
            }
            return config.Id;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    private static List<WSM_Capacity_Filter__c> buildFilterRecords(CapacityInput input, Id capacityQueryId) {
        List<WSM_Capacity_Filter__c> filters = new List<WSM_Capacity_Filter__c>();
        if (input.filters == null) {
            return filters;
        }
        Integer autoNumber = 0;
        for (CapacityFilterInput f : input.filters) {
            autoNumber++;
            WSM_Capacity_Filter__c filter = new WSM_Capacity_Filter__c();
            if (capacityQueryId != null) {
                filter.WSM_Capacity_Query__c = capacityQueryId;
            }
            // Fall back to position so an editor that never set the number still produces
            // filters that Filter Logic can refer to.
            filter.WSM_Filter_Number__c = f.filterNumber == null ? autoNumber : f.filterNumber;
            filter.WSM_Field__c = f.fieldName;
            filter.WSM_Operator__c = f.operator;
            filter.WSM_Value_Source__c = String.isBlank(f.valueSource)
                ? WSM_CapacityQueryBuilder.SRC_LITERAL : f.valueSource;
            filter.WSM_Value__c = f.value;
            filter.WSM_Routed_Record_Field__c = f.routedRecordField;
            filters.add(filter);
        }
        return filters;
    }

    @AuraEnabled
    public static void deleteCapacityQuery(Id capacityQueryId) {
        try {
            delete new WSM_Capacity_Query__c(Id = capacityQueryId);
        } catch (Exception e) {
            throw friendlyError(e.getMessage());
        }
    }

    /**
     * Queryable objects the admin can count, so the editor offers a picker instead of
     * asking anyone to type an API name. Custom objects and the common standard ones only:
     * the full global describe runs to thousands of entries in a mature org and is
     * unusable as a dropdown.
     */
    @AuraEnabled(cacheable=true)
    public static List<ObjectOption> describeCountableObjects() {
        List<ObjectOption> options = new List<ObjectOption>();
        Set<String> alwaysInclude = new Set<String>{
            'account', 'contact', 'lead', 'opportunity', 'case', 'task', 'event',
            'campaign', 'contract', 'order', 'quote', 'asset', 'product2'
        };
        for (SObjectType objectType : Schema.getGlobalDescribe().values()) {
            DescribeSObjectResult d = objectType.getDescribe();
            String apiName = d.getName();
            Boolean isCustom = apiName.endsWithIgnoreCase('__c');
            if (!d.isQueryable() || d.isDeprecatedAndHidden()) {
                continue;
            }
            if (!isCustom && !alwaysInclude.contains(apiName.toLowerCase())) {
                continue;
            }
            ObjectOption option = new ObjectOption();
            option.apiName = apiName;
            option.label = d.getLabel();
            options.add(option);
        }
        options.sort(new ObjectOptionComparator());
        return options;
    }

    private class ObjectOptionComparator implements Comparator<ObjectOption> {
        public Integer compare(ObjectOption a, ObjectOption b) {
            Integer byLabel = a.label.compareTo(b.label);
            return byLabel != 0 ? byLabel : a.apiName.compareTo(b.apiName);
        }
    }

    /**
     * Filterable fields on one object, with their types, groupability and picklist values,
     * so the editor can offer the right operators and a value picker rather than free text.
     */
    @AuraEnabled(cacheable=true)
    public static List<FieldOption> describeFilterableFields(String objectName) {
        List<FieldOption> options = new List<FieldOption>();
        if (String.isBlank(objectName)) {
            return options;
        }
        SObjectType objectType = Schema.getGlobalDescribe().get(objectName.trim().toLowerCase());
        if (objectType == null) {
            throw friendlyError('There is no object called \'' + objectName + '\' in this org.');
        }
        for (SObjectField field : objectType.getDescribe().fields.getMap().values()) {
            DescribeFieldResult d = field.getDescribe();
            if (!d.isFilterable()) {
                continue;
            }
            FieldOption option = new FieldOption();
            option.apiName = d.getName();
            option.label = d.getLabel();
            option.fieldType = d.getType().name();
            option.groupable = d.isGroupable();
            option.picklistValues = new List<String>();
            if (d.getType() == DisplayType.PICKLIST || d.getType() == DisplayType.MULTIPICKLIST) {
                for (PicklistEntry entry : d.getPicklistValues()) {
                    if (entry.isActive()) {
                        option.picklistValues.add(entry.getValue());
                    }
                }
            }
            options.add(option);
        }
        options.sort(new FieldOptionComparator());
        return options;
    }

    private class FieldOptionComparator implements Comparator<FieldOption> {
        public Integer compare(FieldOption a, FieldOption b) {
            Integer byLabel = a.label.compareTo(b.label);
            return byLabel != 0 ? byLabel : a.apiName.compareTo(b.apiName);
        }
    }

    // Shapes of the JSON the capacity editor posts. Not @AuraEnabled: built only by
    // JSON.deserialize() from the LWC request body, never returned to the client.
    private class CapacityInput {
        public Id id;
        public Id groupId;
        public String label;
        public String objectName;
        public String ownerField;
        public String role;
        public Integer cap;
        public Decimal loadWeight;
        public String filterLogic;
        public Boolean active;
        public Integer sortOrder;
        public String description;
        public List<CapacityFilterInput> filters;
    }

    private class CapacityFilterInput {
        public Integer filterNumber;
        public String fieldName;
        public String operator;
        public String valueSource;
        public String value;
        public String routedRecordField;
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
