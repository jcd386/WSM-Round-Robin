/**
 * Mutable in-transaction wrapper around one WSM_Round_Robin_Group__c row plus its
 * member states. msSequence backs the replayable last-assigned stamping: every pick
 * within this group during this transaction gets txnBase + (msSequence++) milliseconds,
 * so bulk requests against the same group in one call produce a strictly increasing,
 * deterministic order even though they share a single Datetime.now() base.
 */
public class WSM_GroupState {

    public WSM_Round_Robin_Group__c record;
    public List<WSM_MemberState> members;
    public Integer msSequence;

    public WSM_GroupState(WSM_Round_Robin_Group__c record) {
        this.record = record;
        this.members = new List<WSM_MemberState>();
        this.msSequence = 0;
    }

    public List<WSM_Round_Robin_Member__c> dirtyRecords() {
        List<WSM_Round_Robin_Member__c> dirty = new List<WSM_Round_Robin_Member__c>();
        for (WSM_MemberState state : members) {
            if (state.dirty) {
                state.flushToRecord();
                dirty.add(state.record);
            }
        }
        return dirty;
    }
}
