/**
 * Sole owner of every SOQL statement the engine issues. Kept as one class so the
 * engine's query footprint is auditable in one place, and so tests can swap in a stub
 * subclass that overrides lockGroups() to simulate UNABLE_TO_LOCK_ROW without needing
 * two concurrent transactions.
 *
 * Footprint per assign() call, flat with respect to batch size and pool size:
 *   ≤2 resolve/lock + 1 member + ≤3 period aggregates
 *   + 1 capacity config + 1 aggregate per active capacity query (capped at
 *     MAX_CAPACITY_QUERIES) + ≤1 routed-record read per distinct routed object type.
 *
 * capacityAggregate() and routedRecords() are the only methods that touch the customer's
 * own objects rather than the package's. Both run in SYSTEM_MODE on purpose: the package
 * is designed to be called from guest and community contexts where the running user
 * cannot read the very record they just created, so a USER_MODE count would come back
 * zero and silently misroute. The blast radius is held down structurally instead:
 * capacityAggregate() can only ever return COUNT(Id) plus group-by keys (never record
 * field values), and routedRecords() only reads fields the group's own config names, only
 * from record Ids the caller explicitly handed in.
 */
public inherited sharing virtual class WSM_RoundRobinSelector {

    /** Locks every requested group row so concurrent engine transactions serialize on it. */
    public virtual List<WSM_Round_Robin_Group__c> lockGroups(Set<Id> groupIds) {
        return [
            SELECT Id, Name, WSM_Active__c, WSM_Algorithm__c, WSM_Capacity_Mode__c, WSM_Period__c,
                   WSM_Default_Member_Cap__c, WSM_Fallback_User__c, WSM_Fallback_Queue_Id__c, WSM_Calibration__c, WSM_Developer_Name__c
            FROM WSM_Round_Robin_Group__c
            WHERE Id IN :groupIds
            FOR UPDATE
        ];
    }

    /** Read-only group fetch for preview() — never locks, never blocks on a live assign(). */
    public virtual List<WSM_Round_Robin_Group__c> queryGroups(Set<Id> groupIds) {
        return [
            SELECT Id, Name, WSM_Active__c, WSM_Algorithm__c, WSM_Capacity_Mode__c, WSM_Period__c,
                   WSM_Default_Member_Cap__c, WSM_Fallback_User__c, WSM_Fallback_Queue_Id__c, WSM_Calibration__c, WSM_Developer_Name__c
            FROM WSM_Round_Robin_Group__c
            WHERE Id IN :groupIds
        ];
    }

    /**
     * One query for every member across every requested group. No FOR UPDATE — the
     * group lock already serializes engine writers, and the admin UI only ever touches
     * disjoint fields (weight, active, OOO) that don't race with an in-flight pick.
     */
    public virtual List<WSM_Round_Robin_Member__c> membersForGroups(Set<Id> groupIds) {
        return [
            SELECT Id, Name, WSM_Group__c, WSM_User__c, WSM_User__r.Name, WSM_Active__c, WSM_Weight__c,
                   WSM_Cap_Override__c, WSM_OOO_Start_Date__c, WSM_OOO_Return_Date__c, WSM_Last_Assigned__c,
                   WSM_Rotation_Value__c, WSM_Sort_Order__c, WSM_Total_Assignments__c, WSM_Tier__c
            FROM WSM_Round_Robin_Member__c
            WHERE WSM_Group__c IN :groupIds
            ORDER BY WSM_Group__c, WSM_Tier__c NULLS FIRST, WSM_Sort_Order__c NULLS LAST, Id
        ];
    }

    /**
     * Per-member assignment counts since periodStart, for every group in groupIds. Call
     * once per distinct period-start value across the requested groups (at most 3 —
     * Daily/Weekly/Monthly) rather than once per group.
     */
    public virtual AggregateResult[] periodCounts(Set<Id> groupIds, Datetime periodStart) {
        return [
            SELECT WSM_Member__c memberId, COUNT(Id) cnt
            FROM WSM_Assignment_Log__c
            WHERE WSM_Group__c IN :groupIds
              AND WSM_Status__c = 'Assigned'
              AND WSM_Member__c != null
              AND CreatedDate >= :periodStart
            GROUP BY WSM_Member__c
        ];
    }

    /** Resolves developer names to groups in one query for the whole batch. */
    public virtual List<WSM_Round_Robin_Group__c> resolveDeveloperNames(Set<String> developerNames) {
        return [
            SELECT Id, WSM_Developer_Name__c
            FROM WSM_Round_Robin_Group__c
            WHERE WSM_Developer_Name__c IN :developerNames
        ];
    }

    /**
     * Every active Capacity Query for the requested groups, with its filters, in one
     * query. Inactive rows are filtered out here so they cost nothing downstream.
     */
    public virtual List<WSM_Capacity_Query__c> capacityQueriesForGroups(Set<Id> groupIds) {
        return [
            SELECT Id, Name, WSM_Group__c, WSM_Label__c, WSM_Object__c, WSM_Owner_Field__c,
                   WSM_Role__c, WSM_Cap__c, WSM_Load_Weight__c, WSM_Filter_Logic__c,
                   WSM_Active__c, WSM_Sort_Order__c,
                   (SELECT Id, WSM_Filter_Number__c, WSM_Field__c, WSM_Operator__c,
                           WSM_Value_Source__c, WSM_Value__c, WSM_Routed_Record_Field__c
                    FROM Filters__r
                    ORDER BY WSM_Filter_Number__c)
            FROM WSM_Capacity_Query__c
            WHERE WSM_Group__c IN :groupIds
              AND WSM_Active__c = true
            ORDER BY WSM_Group__c, WSM_Sort_Order__c NULLS LAST, Id
        ];
    }

    /**
     * Runs one compiled capacity query. The SOQL text comes from
     * WSM_CapacityQueryBuilder.toSoql(), which only ever emits COUNT(Id) plus group-by
     * keys against schema-resolved names, and every value arrives as a bind. See the
     * class header for why this is SYSTEM_MODE.
     */
    public virtual List<AggregateResult> capacityAggregate(String soql, Map<String, Object> bindMap) {
        return (List<AggregateResult>) Database.queryWithBinds(soql, bindMap, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Reads the named fields off the records the caller asked us to route, so a capacity
     * query can filter on a value from the incoming record. fieldNames must already be
     * schema-resolved by the caller; this method does no validation of its own and must
     * never be handed a raw admin string.
     */
    public virtual List<SObject> routedRecords(String objectName, Set<String> fieldNames, Set<Id> recordIds) {
        List<String> selectList = new List<String>{ 'Id' };
        for (String fieldName : fieldNames) {
            if (fieldName != 'Id') {
                selectList.add(fieldName);
            }
        }
        String soql = 'SELECT ' + String.join(selectList, ', ')
            + ' FROM ' + objectName
            + ' WHERE Id IN :recordIds';
        return Database.queryWithBinds(soql, new Map<String, Object>{ 'recordIds' => new List<Id>(recordIds) },
            AccessLevel.SYSTEM_MODE);
    }
}
