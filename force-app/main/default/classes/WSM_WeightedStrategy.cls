/**
 * Stride-based weighted rotation: stride = 1000 / weight (weight null defaults to 1,
 * clamped 1-100 defensively even though the member trigger already enforces the
 * range). Picks the lowest effective rotation value; a null rotation value (a brand
 * new seat) is treated as EPSILON below the current pool minimum so a joiner is
 * guaranteed the very next slot rather than merely tying for it. A plain tie at the
 * pool minimum isn't enough — a joiner recomputes "effective = poolMin" fresh on every
 * call, so with a plain tie it can lose the tie-break (Last Assigned/Sort Order/Id) to
 * the same front-runner forever and never receive a real rotation value. Subtracting
 * EPSILON makes the joiner strictly less than any exact-poolMin match, so it always
 * wins its first eligible round; after that it holds a real rotation value and follows
 * normal cadence like everyone else. Only the winning row's rotation value changes
 * here — lastAssigned/period-count bookkeeping is the engine's job.
 */
public inherited sharing class WSM_WeightedStrategy implements WSM_ISelectionStrategy {

    private static final Decimal BASE_STRIDE = 1000.0;
    private static final Decimal MIN_WEIGHT = 1;
    private static final Decimal MAX_WEIGHT = 100;
    private static final Decimal JOINER_EPSILON = 0.000001;

    public List<WSM_MemberState> sortMembers(List<WSM_MemberState> members) {
        Decimal poolMin = poolMinRotation(members);
        List<WSM_MemberState> ordered = members.clone();
        ordered.sort(new RankComparator(poolMin));
        return ordered;
    }

    public WSM_MemberState selectNext(List<WSM_MemberState> eligibleMembers) {
        if (eligibleMembers.isEmpty()) {
            return null;
        }
        Decimal poolMin = poolMinRotation(eligibleMembers);
        List<WSM_MemberState> ordered = eligibleMembers.clone();
        ordered.sort(new RankComparator(poolMin));
        WSM_MemberState winner = ordered[0];
        Decimal effective = effectiveRotation(winner, poolMin);
        Decimal stride = BASE_STRIDE / clampWeight(winner.record.WSM_Weight__c);
        winner.rotationValue = effective + stride;
        winner.dirty = true;
        return winner;
    }

    private static Decimal effectiveRotation(WSM_MemberState m, Decimal poolMin) {
        return m.rotationValue == null ? (poolMin - JOINER_EPSILON) : m.rotationValue;
    }

    private Decimal poolMinRotation(List<WSM_MemberState> members) {
        Decimal minValue;
        for (WSM_MemberState m : members) {
            if (m.rotationValue == null) {
                continue;
            }
            if (minValue == null || m.rotationValue < minValue) {
                minValue = m.rotationValue;
            }
        }
        return minValue == null ? 0 : minValue;
    }

    private static Decimal clampWeight(Decimal weight) {
        Decimal w = weight == null ? 1 : weight;
        if (w < MIN_WEIGHT) {
            return MIN_WEIGHT;
        }
        if (w > MAX_WEIGHT) {
            return MAX_WEIGHT;
        }
        return w;
    }

    private class RankComparator implements Comparator<WSM_MemberState> {
        private Decimal poolMin;

        RankComparator(Decimal poolMin) {
            this.poolMin = poolMin;
        }

        public Integer compare(WSM_MemberState a, WSM_MemberState b) {
            Decimal effA = effectiveRotation(a, poolMin);
            Decimal effB = effectiveRotation(b, poolMin);
            if (effA != effB) {
                return effA < effB ? -1 : 1;
            }
            Integer byLastAssigned = compareDatetimeNullsFirst(a.lastAssigned, b.lastAssigned);
            if (byLastAssigned != 0) {
                return byLastAssigned;
            }
            Integer bySortOrder = compareDecimalNullsLast(a.record.WSM_Sort_Order__c, b.record.WSM_Sort_Order__c);
            if (bySortOrder != 0) {
                return bySortOrder;
            }
            return compareIds(a.record.Id, b.record.Id);
        }
    }

    private static Integer compareDatetimeNullsFirst(Datetime a, Datetime b) {
        if (a == null && b == null) {
            return 0;
        }
        if (a == null) {
            return -1;
        }
        if (b == null) {
            return 1;
        }
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    private static Integer compareDecimalNullsLast(Decimal a, Decimal b) {
        if (a == null && b == null) {
            return 0;
        }
        if (a == null) {
            return 1;
        }
        if (b == null) {
            return -1;
        }
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    private static Integer compareIds(Id a, Id b) {
        return String.valueOf(a).compareTo(String.valueOf(b));
    }
}
