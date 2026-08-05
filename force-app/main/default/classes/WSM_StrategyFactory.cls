public inherited sharing class WSM_StrategyFactory {

    public static final String STRICT_ROTATION = 'Strict Rotation';
    public static final String WEIGHTED = 'Weighted';
    public static final String LEAST_ASSIGNED = 'Least Assigned';

    /** Unknown/blank algorithm values default to Strict Rotation and append a warning. */
    public static WSM_ISelectionStrategy create(String algorithm, String calibration, List<String> warnings) {
        if (algorithm == WEIGHTED) {
            return new WSM_WeightedStrategy();
        }
        if (algorithm == LEAST_ASSIGNED) {
            return new WSM_LeastAssignedStrategy(calibration);
        }
        if (algorithm != STRICT_ROTATION && warnings != null) {
            warnings.add('Unknown algorithm \'' + algorithm + '\' - defaulted to Strict Rotation.');
        }
        return new WSM_StrictRotationStrategy();
    }
}
