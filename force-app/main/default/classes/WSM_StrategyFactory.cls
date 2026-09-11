public inherited sharing class WSM_StrategyFactory {

    public static final String STRICT_ROTATION = 'Strict Rotation';
    public static final String WEIGHTED = 'Weighted';
    public static final String LEAST_ASSIGNED = 'Least Assigned';
    public static final String LEAST_LOADED = 'Least Loaded';

    /** Unknown/blank algorithm values default to Strict Rotation and append a warning. */
    public static WSM_ISelectionStrategy create(String algorithm, String calibration, List<String> warnings) {
        return create(algorithm, calibration, true, warnings);
    }

    /**
     * hasLoadMetric says whether the group actually has a Load Metric capacity query to
     * rank on. Least Loaded without one would silently rank every member at zero load and
     * collapse to the tie-breaks, so it degrades to Strict Rotation with a warning instead
     * of pretending to work.
     */
    public static WSM_ISelectionStrategy create(String algorithm, String calibration, Boolean hasLoadMetric,
            List<String> warnings) {
        if (algorithm == WEIGHTED) {
            return new WSM_WeightedStrategy();
        }
        if (algorithm == LEAST_ASSIGNED) {
            return new WSM_LeastAssignedStrategy(calibration);
        }
        if (algorithm == LEAST_LOADED) {
            if (hasLoadMetric == true) {
                return new WSM_ExternalLoadStrategy();
            }
            if (warnings != null) {
                warnings.add('Least Loaded needs a capacity query with a Load Metric role - defaulted to Strict Rotation.');
            }
            return new WSM_StrictRotationStrategy();
        }
        if (algorithm != STRICT_ROTATION && warnings != null) {
            warnings.add('Unknown algorithm \'' + algorithm + '\' - defaulted to Strict Rotation.');
        }
        return new WSM_StrictRotationStrategy();
    }
}
