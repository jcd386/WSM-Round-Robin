/**
 * Pure algorithm-math tests against the strategy classes directly, using in-memory
 * WSM_MemberState objects with synthetic (unsaved) Ids — no DML, no org config. Engine
 * integration (real caps, real OOO gates, real period aggregates, bulk/concurrency) is
 * covered separately in WSM_RoundRobinEngine_Test. Real assertions throughout — this
 * suite is exempted from the org's coverage-only convention because algorithm
 * correctness is the entire point of the product (see plan §Test strategy).
 */
@isTest
private class WSM_Strategies_Test {

    private static Integer idSeq = 0;

    private static Id fakeId() {
        idSeq++;
        return WSM_Round_Robin_Member__c.SObjectType.getDescribe().getKeyPrefix() + String.valueOf(idSeq).leftPad(12, '0');
    }

    private static WSM_MemberState memberState(Decimal weight, Decimal rotationValue, Datetime lastAssigned, Decimal sortOrder) {
        WSM_Round_Robin_Member__c rec = new WSM_Round_Robin_Member__c(
            Id = fakeId(),
            WSM_Weight__c = weight,
            WSM_Rotation_Value__c = rotationValue,
            WSM_Last_Assigned__c = lastAssigned,
            WSM_Sort_Order__c = sortOrder,
            WSM_Active__c = true
        );
        return new WSM_MemberState(rec);
    }

    // ---------- Strict Rotation ----------

    @isTest
    static void strictRotation_nullLastAssignedBeatsRealValue() {
        WSM_MemberState withValue = memberState(1, null, Datetime.now(), 0);
        WSM_MemberState withNull = memberState(1, null, null, 1);

        WSM_MemberState winner = new WSM_StrictRotationStrategy().selectNext(new List<WSM_MemberState>{ withValue, withNull });

        System.assertEquals(withNull.record.Id, winner.record.Id, 'A never-assigned member (null Last Assigned) must be picked before one with a real timestamp.');
    }

    @isTest
    static void strictRotation_sortOrderBreaksLastAssignedTie_nullSortOrderLast() {
        WSM_MemberState hasSortOrder = memberState(1, null, null, 5);
        WSM_MemberState blankSortOrder = memberState(1, null, null, null);

        WSM_MemberState winner = new WSM_StrictRotationStrategy().selectNext(new List<WSM_MemberState>{ blankSortOrder, hasSortOrder });

        System.assertEquals(hasSortOrder.record.Id, winner.record.Id, 'When Last Assigned ties, a real Sort Order must beat a blank one (nulls last).');
    }

    @isTest
    static void strictRotation_idBreaksFinalTie() {
        WSM_MemberState first = memberState(1, null, null, null);
        WSM_MemberState second = memberState(1, null, null, null);

        WSM_MemberState winner = new WSM_StrictRotationStrategy().selectNext(new List<WSM_MemberState>{ second, first });

        System.assertEquals(first.record.Id, winner.record.Id, 'With every other key tied, the lower record Id must win.');
    }

    @isTest
    static void strictRotation_cyclesThroughPool_1_2_3_1() {
        WSM_MemberState m1 = memberState(1, null, null, 0);
        WSM_MemberState m2 = memberState(1, null, null, 1);
        WSM_MemberState m3 = memberState(1, null, null, 2);
        List<WSM_MemberState> pool = new List<WSM_MemberState>{ m1, m2, m3 };
        WSM_ISelectionStrategy strategy = new WSM_StrictRotationStrategy();

        WSM_MemberState pick1 = strategy.selectNext(pool);
        System.assertEquals(m1.record.Id, pick1.record.Id, 'Round 1 should pick member 1 (all null, sort order breaks the tie).');
        pick1.lastAssigned = Datetime.newInstance(2026, 1, 1, 0, 0, 0);

        WSM_MemberState pick2 = strategy.selectNext(pool);
        System.assertEquals(m2.record.Id, pick2.record.Id, 'Round 2 should pick member 2 (still null, next by sort order).');
        pick2.lastAssigned = Datetime.newInstance(2026, 1, 1, 0, 0, 1);

        WSM_MemberState pick3 = strategy.selectNext(pool);
        System.assertEquals(m3.record.Id, pick3.record.Id, 'Round 3 should pick member 3 (the last remaining null).');
        pick3.lastAssigned = Datetime.newInstance(2026, 1, 1, 0, 0, 2);

        WSM_MemberState pick4 = strategy.selectNext(pool);
        System.assertEquals(m1.record.Id, pick4.record.Id, 'Round 4 should cycle back to member 1 (oldest real Last Assigned).');
    }

    // ---------- Weighted ----------

    @isTest
    static void weighted_nullRotationJoinsAtPoolMinimum() {
        // established sits at the true pool minimum (0). A joiner (null rotation) must
        // win outright over it, not merely tie — a plain tie recomputed fresh every round
        // could lose the tie-break to the same front-runner forever and never settle.
        WSM_MemberState established = memberState(1, 0, null, 0);
        WSM_MemberState joiner = memberState(1, null, null, 1);

        WSM_MemberState winner = new WSM_WeightedStrategy().selectNext(new List<WSM_MemberState>{ established, joiner });

        System.assertEquals(joiner.record.Id, winner.record.Id, 'A brand new seat (null rotation) must win its first eligible round outright, not just tie for it.');
        System.assert(Math.abs(joiner.rotationValue - 1000) < 0.001, 'After the pick, rotation should be ~pool min (0) plus the stride (1000). Got ' + joiner.rotationValue);
    }

    @isTest
    static void weighted_onlyPickedRowBecomesDirty() {
        WSM_MemberState a = memberState(1, 0, null, 0);
        WSM_MemberState b = memberState(1, 1000, null, 1);

        WSM_MemberState winner = new WSM_WeightedStrategy().selectNext(new List<WSM_MemberState>{ a, b });

        System.assertEquals(a.record.Id, winner.record.Id);
        System.assertEquals(true, a.dirty, 'The picked row must be marked dirty.');
        System.assertEquals(false, b.dirty, 'A row that was not picked must never be marked dirty.');
    }

    @isTest
    static void weighted_prospectiveWeightChangeAppliesImmediately() {
        WSM_MemberState a = memberState(1, 0, null, 0);
        WSM_MemberState b = memberState(1, 1000, null, 1);

        a.record.WSM_Weight__c = 3; // changed after the seat was created, before this pick

        WSM_MemberState winner = new WSM_WeightedStrategy().selectNext(new List<WSM_MemberState>{ a, b });

        System.assertEquals(a.record.Id, winner.record.Id);
        Decimal expectedStride = 1000.0 / 3;
        System.assert(Math.abs(winner.rotationValue - expectedStride) < 0.0001,
            'Stride must be computed from the CURRENT weight at pick time, not a cached value. Got ' + winner.rotationValue);
    }

    @isTest
    static void weighted_distributionOver50Picks_matches3to1to1() {
        WSM_MemberState heavy = memberState(3, null, null, 0);
        WSM_MemberState lightA = memberState(1, null, null, 1);
        WSM_MemberState lightB = memberState(1, null, null, 2);
        List<WSM_MemberState> pool = new List<WSM_MemberState>{ heavy, lightA, lightB };
        WSM_ISelectionStrategy strategy = new WSM_WeightedStrategy();

        Map<Id, Integer> pickCounts = new Map<Id, Integer>{ heavy.record.Id => 0, lightA.record.Id => 0, lightB.record.Id => 0 };
        for (Integer i = 0; i < 50; i++) {
            WSM_MemberState winner = strategy.selectNext(pool);
            pickCounts.put(winner.record.Id, pickCounts.get(winner.record.Id) + 1);
        }

        System.assertEquals(50, pickCounts.get(heavy.record.Id) + pickCounts.get(lightA.record.Id) + pickCounts.get(lightB.record.Id));
        System.assert(Math.abs(pickCounts.get(heavy.record.Id) - 30) <= 1, 'Weight-3 member expected ~30/50 picks, got ' + pickCounts.get(heavy.record.Id));
        System.assert(Math.abs(pickCounts.get(lightA.record.Id) - 10) <= 1, 'Weight-1 member A expected ~10/50 picks, got ' + pickCounts.get(lightA.record.Id));
        System.assert(Math.abs(pickCounts.get(lightB.record.Id) - 10) <= 1, 'Weight-1 member B expected ~10/50 picks, got ' + pickCounts.get(lightB.record.Id));
    }

    @isTest
    static void weighted_joinerGetsOneFrontSlotThenNormalCadence() {
        WSM_MemberState established = memberState(1, 0, null, 0);
        WSM_MemberState farBehind = memberState(1, 500, null, 1);
        WSM_MemberState joiner = memberState(1, null, null, 2);
        List<WSM_MemberState> pool = new List<WSM_MemberState>{ established, farBehind, joiner };
        WSM_ISelectionStrategy strategy = new WSM_WeightedStrategy();

        WSM_MemberState pick1 = strategy.selectNext(pool);
        System.assertEquals(joiner.record.Id, pick1.record.Id, 'The joiner gets the very next slot, ahead of even the established front-runner.');

        WSM_MemberState pick2 = strategy.selectNext(pool);
        System.assertEquals(established.record.Id, pick2.record.Id, 'With the joiner settled, normal cadence resumes: the true front-runner goes next.');

        WSM_MemberState pick3 = strategy.selectNext(pool);
        System.assertEquals(farBehind.record.Id, pick3.record.Id, 'The member who was already far behind is served once the others catch up to its position.');
    }

    // ---------- Least Assigned ----------

    @isTest
    static void leastAssigned_medianCalibrationNormalizesNewJoiner_vsNoneFloods() {
        Datetime recent = Datetime.now();
        Datetime older = recent.addDays(-10);

        // Sorted raw counts [0, 2, 3, 5] -> median = avg(2,3) = 2.5 -> floor 2.
        WSM_MemberState joiner = memberState(1, null, recent, 0);
        joiner.periodCount = 0;
        WSM_MemberState regular = memberState(1, null, older, 1);
        regular.periodCount = 2;
        WSM_MemberState controlC = memberState(1, null, null, 2);
        controlC.periodCount = 3;
        WSM_MemberState controlD = memberState(1, null, null, 3);
        controlD.periodCount = 5;
        List<WSM_MemberState> pool = new List<WSM_MemberState>{ joiner, regular, controlC, controlD };

        WSM_MemberState medianWinner = new WSM_LeastAssignedStrategy('Median').selectNext(pool);
        System.assertEquals(regular.record.Id, medianWinner.record.Id,
            'Under Median calibration the joiner is normalized to the pool median (2), tying with the regular member, and the OLDER Last Assigned wins the tie.');

        WSM_MemberState noneWinner = new WSM_LeastAssignedStrategy('None').selectNext(pool);
        System.assertEquals(joiner.record.Id, noneWinner.record.Id,
            'Under Calibration=None the joiner keeps its true zero count and wins outright, demonstrating the catch-up flood Median exists to prevent.');
    }

    @isTest
    static void leastAssigned_pickIsMinimumCount() {
        WSM_MemberState low = memberState(1, null, null, 0);
        low.periodCount = 1;
        WSM_MemberState high = memberState(1, null, null, 1);
        high.periodCount = 4;

        WSM_MemberState winner = new WSM_LeastAssignedStrategy('None').selectNext(new List<WSM_MemberState>{ high, low });

        System.assertEquals(low.record.Id, winner.record.Id, 'The member with fewer assignments this period must be picked.');
    }

    @isTest
    static void leastAssigned_tieBreaksByOldestLastAssignedThenSortOrderThenId() {
        WSM_MemberState a = memberState(1, null, null, 0);
        a.periodCount = 2;
        WSM_MemberState b = memberState(1, null, null, 1);
        b.periodCount = 2;

        WSM_MemberState winner = new WSM_LeastAssignedStrategy('None').selectNext(new List<WSM_MemberState>{ b, a });

        System.assertEquals(a.record.Id, winner.record.Id, 'Equal counts with both Last Assigned null must fall through to Sort Order.');
    }

    // ---------- Factory ----------

    @isTest
    static void factory_unknownAlgorithmDefaultsToStrictAndWarns() {
        List<String> warnings = new List<String>();
        WSM_ISelectionStrategy strategy = WSM_StrategyFactory.create('Round Robin Roulette', 'Median', warnings);

        System.assert(strategy instanceof WSM_StrictRotationStrategy, 'An unrecognized algorithm value must default to Strict Rotation.');
        System.assertEquals(1, warnings.size(), 'A warning must be recorded when the algorithm value is unrecognized.');
        System.assert(warnings[0].contains('Round Robin Roulette'), 'The warning should reference the bad value for troubleshooting.');
    }

    @isTest
    static void factory_recognizedAlgorithmsProduceNoWarning() {
        List<String> warnings = new List<String>();
        System.assert(WSM_StrategyFactory.create('Strict Rotation', 'Median', warnings) instanceof WSM_StrictRotationStrategy);
        System.assert(WSM_StrategyFactory.create('Weighted', 'Median', warnings) instanceof WSM_WeightedStrategy);
        System.assert(WSM_StrategyFactory.create('Least Assigned', 'Median', warnings) instanceof WSM_LeastAssignedStrategy);
        System.assertEquals(0, warnings.size(), 'None of the three canonical algorithm values should produce a warning.');
    }
}
