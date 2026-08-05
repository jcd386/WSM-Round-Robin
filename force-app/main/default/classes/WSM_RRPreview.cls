/**
 * Dry-run result of WSM_RoundRobinService.preview(groupId) — no lock, no DML. Verdicts
 * are returned in member query order (WSM_Sort_Order__c, Id); use sortRank on each
 * verdict for the algorithm's actual pick order among eligible members.
 */
public class WSM_RRPreview {

    public Id groupId;
    public Id wouldAssignUserId;
    public Id wouldAssignMemberId;
    public List<MemberVerdict> verdicts;

    public WSM_RRPreview() {
        this.verdicts = new List<MemberVerdict>();
    }

    /**
     * One member's eligibility outcome for this dry run. sortRank is 1-based and only
     * populated for eligible members (1 = would be picked next); ineligible members
     * carry null since they have no place in the pick order.
     */
    public class MemberVerdict {
        public Id memberId;
        public Id userId;
        public String userName;
        public Boolean eligible;
        public String skipReason;
        public Integer sortRank;
    }
}
