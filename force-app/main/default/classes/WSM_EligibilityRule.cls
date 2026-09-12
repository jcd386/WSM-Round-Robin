/**
 * One eligibility gate. Implementations are pure functions of the member/group state
 * passed in, no SOQL, no DML, so the same rule runs identically inside a locked
 * assign() transaction and inside the lock-free preview().
 */
public interface WSM_EligibilityRule {

    /** Returns null when the member is eligible, or a human-readable skip reason when not. */
    String evaluate(WSM_MemberState member, WSM_GroupState grp, Date today);
}
