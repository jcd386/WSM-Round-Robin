/**
 * Mutable in-transaction wrapper around one WSM_Round_Robin_Group__c row plus its
 * member states. msSequence backs the replayable last-assigned stamping: every pick
 * within this group during this transaction gets txnBase + (msSequence++) milliseconds,
 * so bulk requests against the same group in one call produce a strictly increasing,
 * deterministic order even though they share a single Datetime.now() base.
 *
 * capacityQueries holds the group's compiled Capacity Query definitions, valid and
 * invalid alike. Invalid ones are kept so the engine can report why they were ignored
 * rather than failing silently.
 */
public class WSM_GroupState {

    public WSM_Round_Robin_Group__c record;
    public List<WSM_MemberState> members;
    public Integer msSequence;
    public List<WSM_CapacityQueryDef> capacityQueries;

    public WSM_GroupState(WSM_Round_Robin_Group__c record) {
        this.record = record;
        this.members = new List<WSM_MemberState>();
        this.msSequence = 0;
        this.capacityQueries = new List<WSM_CapacityQueryDef>();
    }

    /** True when at least one compiled definition can actually feed the Least Loaded ranking. */
    public Boolean hasLoadMetric {
        get {
            for (WSM_CapacityQueryDef def : capacityQueries) {
                if (def.isValid == true && def.isLoadMetric) {
                    return true;
                }
            }
            return false;
        }
    }

    /** Reasons any capacity query failed to compile, for the assignment log's warning line. */
    public List<String> capacityWarnings {
        get {
            List<String> warnings = new List<String>();
            for (WSM_CapacityQueryDef def : capacityQueries) {
                if (def.isValid != true) {
                    warnings.add('Capacity query \'' + def.label + '\' ignored: ' + def.invalidReason);
                }
            }
            return warnings;
        }
    }

    /** Ascending list of the tiers actually present on this group's members. */
    public List<Integer> tiers {
        get {
            Set<Integer> distinct = new Set<Integer>();
            for (WSM_MemberState member : members) {
                distinct.add(member.tier);
            }
            List<Integer> ordered = new List<Integer>(distinct);
            ordered.sort();
            return ordered;
        }
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
