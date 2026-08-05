/**
 * Sole owner of every SOQL statement the engine issues. Kept as one class so the
 * engine's query footprint (documented in the plan: ≤2 resolve/lock + 1 member + ≤3
 * period-aggregate queries per assign() call) is auditable in one place, and so tests
 * can swap in a stub subclass that overrides lockGroups() to simulate
 * UNABLE_TO_LOCK_ROW without needing two concurrent transactions.
 */
public inherited sharing virtual class WSM_RoundRobinSelector {

    /** Locks every requested group row so concurrent engine transactions serialize on it. */
    public virtual List<WSM_Round_Robin_Group__c> lockGroups(Set<Id> groupIds) {
        return [
            SELECT Id, Name, WSM_Active__c, WSM_Algorithm__c, WSM_Capacity_Mode__c, WSM_Period__c,
                   WSM_Default_Member_Cap__c, WSM_Fallback_User__c, WSM_Calibration__c, WSM_Developer_Name__c
            FROM WSM_Round_Robin_Group__c
            WHERE Id IN :groupIds
            FOR UPDATE
        ];
    }

    /** Read-only group fetch for preview() — never locks, never blocks on a live assign(). */
    public virtual List<WSM_Round_Robin_Group__c> queryGroups(Set<Id> groupIds) {
        return [
            SELECT Id, Name, WSM_Active__c, WSM_Algorithm__c, WSM_Capacity_Mode__c, WSM_Period__c,
                   WSM_Default_Member_Cap__c, WSM_Fallback_User__c, WSM_Calibration__c, WSM_Developer_Name__c
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
                   WSM_Rotation_Value__c, WSM_Sort_Order__c, WSM_Total_Assignments__c
            FROM WSM_Round_Robin_Member__c
            WHERE WSM_Group__c IN :groupIds
            ORDER BY WSM_Group__c, WSM_Sort_Order__c NULLS LAST, Id
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
}
