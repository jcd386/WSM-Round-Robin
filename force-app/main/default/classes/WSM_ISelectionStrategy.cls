/**
 * Picks the next member from an already-eligible pool. Algorithm-specific state (e.g.
 * Weighted's rotation value) is mutated on the winning WSM_MemberState by selectNext()
 * itself; universal bookkeeping (lastAssigned stamp, period-count increment, dirty
 * flag) is applied uniformly by the engine after the pick, not here.
 */
public interface WSM_ISelectionStrategy {

    /** Full pick-order ranking of members, used by selectNext() and by preview() for sortRank. */
    List<WSM_MemberState> sortMembers(List<WSM_MemberState> members);

    /** Returns the winner, or null if eligibleMembers is empty. */
    WSM_MemberState selectNext(List<WSM_MemberState> eligibleMembers);
}
