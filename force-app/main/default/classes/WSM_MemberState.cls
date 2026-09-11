/**
 * Mutable in-transaction wrapper around one WSM_Round_Robin_Member__c row. The engine
 * mutates rotationValue/lastAssigned/periodCount here (never directly on the SObject)
 * so a group requested multiple times in one call sees every prior pick's effect
 * before the next request in the same batch is evaluated. dirty is set only for rows
 * that were actually picked; the engine writes only dirty rows back to the SObject at
 * flush time.
 *
 * capacityCounts and externalLoad are filled in by the engine from the group's Capacity
 * Queries before the eligibility pipeline runs, which is what lets WSM_CapacityQueryRule
 * and WSM_ExternalLoadStrategy stay pure comparisons with no SOQL of their own.
 */
public class WSM_MemberState {

    public WSM_Round_Robin_Member__c record;
    public Decimal rotationValue;
    public Datetime lastAssigned;
    public Integer periodCount;
    public Boolean dirty;
    public Integer picksThisCall;

    /** Count per Capacity Query config Id. A missing key means the aggregate returned no row, i.e. zero. */
    public Map<Id, Integer> capacityCounts;

    /** Sum of the Load Metric counts, each times its Load Weight. Ranked on by Least Loaded. */
    public Decimal externalLoad;

    public WSM_MemberState(WSM_Round_Robin_Member__c record) {
        this.record = record;
        this.rotationValue = record.WSM_Rotation_Value__c;
        this.lastAssigned = record.WSM_Last_Assigned__c;
        this.periodCount = 0;
        this.dirty = false;
        this.picksThisCall = 0;
        this.capacityCounts = new Map<Id, Integer>();
        this.externalLoad = 0;
    }

    /** Blank tier is treated as the primary tier so existing groups keep working untouched. */
    public Integer tier {
        get {
            Decimal value = record == null ? null : record.WSM_Tier__c;
            return value == null ? 1 : value.intValue();
        }
    }

    public Integer capacityCount(Id capacityQueryId) {
        Integer count = capacityCounts.get(capacityQueryId);
        return count == null ? 0 : count;
    }

    public void setCapacityCount(Id capacityQueryId, Integer count) {
        capacityCounts.put(capacityQueryId, count == null ? 0 : count);
    }

    /**
     * Recomputes externalLoad from whatever counts are currently loaded. Called by the
     * engine after the aggregates land, and again after a pick so a second request in the
     * same transaction sees the member as one unit busier instead of re-winning on a
     * stale count.
     */
    public void recomputeExternalLoad(List<WSM_CapacityQueryDef> defs) {
        Decimal total = 0;
        if (defs != null) {
            for (WSM_CapacityQueryDef def : defs) {
                if (def.isValid != true || !def.isLoadMetric) {
                    continue;
                }
                total += capacityCount(def.configId) * def.loadWeight;
            }
        }
        this.externalLoad = total;
    }

    /**
     * Charges one unit of work to every Load Metric count after this member wins, so
     * bulk batches level out within a single transaction. The real records land after
     * commit; this keeps the in-memory picture honest until they do.
     */
    public void chargeOnePick(List<WSM_CapacityQueryDef> defs) {
        if (defs == null) {
            return;
        }
        for (WSM_CapacityQueryDef def : defs) {
            if (def.isValid != true || !def.isLoadMetric) {
                continue;
            }
            setCapacityCount(def.configId, capacityCount(def.configId) + 1);
        }
        recomputeExternalLoad(defs);
    }

    /** Copies working state back onto the SObject so it's ready for the bulk update DML. */
    public void flushToRecord() {
        record.WSM_Rotation_Value__c = rotationValue;
        record.WSM_Last_Assigned__c = lastAssigned;
        record.WSM_Total_Assignments__c =
            (record.WSM_Total_Assignments__c == null ? 0 : record.WSM_Total_Assignments__c) + picksThisCall;
    }
}
