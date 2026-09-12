/**
 * Thrown for engine-internal failures that are not modeled as a WSM_RRResult status
 * (e.g. malformed test setup, programmer error). Normal routing outcomes, including
 * lock timeouts, missing groups, and empty pools, are never exceptions; they are
 * always returned as a WSM_RRResult so a single bad request in a batch never aborts
 * the others.
 */
public class WSM_RoundRobinException extends Exception {
}
