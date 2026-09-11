/**
 * Dry-run result of WSM_RoundRobinService.preview(groupId) — no lock, no DML. Verdicts
 * are returned in member query order (WSM_Tier__c, WSM_Sort_Order__c, Id); use sortRank on
 * each verdict for the algorithm's actual pick order among eligible members.
 *
 * Only the winning tier is ranked. Members on a lower-priority tier that was never
 * reached come back eligible with a null sortRank and tierReached = false, which is the
 * honest answer: they were not skipped, they simply were not needed.
 */
public class WSM_RRPreview {

    public Id groupId;
    public Id wouldAssignUserId;
    public Id wouldAssignMemberId;
    public List<MemberVerdict> verdicts;

    /** Configuration problems worth showing the admin, e.g. a capacity query that will not compile. */
    public List<String> warnings;

    /** The tier the pick came from, so the simulator can say "filled from tier 2". */
    public Integer assignedFromTier;

    public WSM_RRPreview() {
        this.verdicts = new List<MemberVerdict>();
        this.warnings = new List<String>();
    }

    /**
     * One member's eligibility outcome for this dry run. sortRank is 1-based and only
     * populated for eligible members on the tier that was actually evaluated (1 = would be
     * picked next); everyone else carries null since they have no place in the pick order.
     */
    public class MemberVerdict {
        public Id memberId;
        public Id userId;
        public String userName;
        public Boolean eligible;
        public String skipReason;
        public Integer sortRank;
        public Integer tier;
        public Boolean tierReached;
        public Decimal externalLoad;
        public List<CapacityReading> capacity;

        public MemberVerdict() {
            this.capacity = new List<CapacityReading>();
        }
    }

    /** What one Capacity Query currently reads for one member, for display in the simulator. */
    public class CapacityReading {
        public Id capacityQueryId;
        public String label;
        public Integer count;
        public Integer cap;
        public Boolean isCap;
        public Boolean isLoadMetric;
        public Boolean atCap;
        /** Set when this reading could not be taken, e.g. it needs a value off a routed record. */
        public String unavailableReason;
    }
}
