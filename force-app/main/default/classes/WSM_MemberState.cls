/**
 * Mutable in-transaction wrapper around one WSM_Round_Robin_Member__c row. The engine
 * mutates rotationValue/lastAssigned/periodCount here (never directly on the SObject)
 * so a group requested multiple times in one call sees every prior pick's effect
 * before the next request in the same batch is evaluated. dirty is set only for rows
 * that were actually picked; the engine writes only dirty rows back to the SObject at
 * flush time.
 */
public class WSM_MemberState {

    public WSM_Round_Robin_Member__c record;
    public Decimal rotationValue;
    public Datetime lastAssigned;
    public Integer periodCount;
    public Boolean dirty;

    public WSM_MemberState(WSM_Round_Robin_Member__c record) {
        this.record = record;
        this.rotationValue = record.WSM_Rotation_Value__c;
        this.lastAssigned = record.WSM_Last_Assigned__c;
        this.periodCount = 0;
        this.dirty = false;
    }

    /** Copies working state back onto the SObject so it's ready for the bulk update DML. */
    public void flushToRecord() {
        record.WSM_Rotation_Value__c = rotationValue;
        record.WSM_Last_Assigned__c = lastAssigned;
        record.WSM_Total_Assignments__c = (record.WSM_Total_Assignments__c == null ? 0 : record.WSM_Total_Assignments__c) + 1;
    }
}
