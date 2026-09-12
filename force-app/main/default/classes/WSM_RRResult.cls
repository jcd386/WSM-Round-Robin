/**
 * Outcome of one WSM_RRRequest. Always returned, even for lock timeouts, missing
 * groups, and empty pools, so a batch of requests never throws on a single bad one.
 */
public class WSM_RRResult {

    public static final String STATUS_ASSIGNED = 'ASSIGNED';
    public static final String STATUS_FALLBACK = 'FALLBACK';
    public static final String STATUS_NO_ELIGIBLE_MEMBERS = 'NO_ELIGIBLE_MEMBERS';
    public static final String STATUS_GROUP_NOT_FOUND = 'GROUP_NOT_FOUND';
    public static final String STATUS_GROUP_INACTIVE = 'GROUP_INACTIVE';
    public static final String STATUS_LOCK_TIMEOUT = 'LOCK_TIMEOUT';
    public static final String STATUS_ERROR = 'ERROR';

    public Boolean isSuccess;
    public String status;
    public Id userId;
    public Id queueId;
    public Id memberId;
    public Id groupId;
    public Id logId;
    public String message;

    /** The Id to drop into OwnerId, the assigned user, or the fallback queue when no user was eligible. */
    public Id ownerId {
        get {
            return userId != null ? userId : queueId;
        }
    }

    public WSM_RRResult() {
    }

    public WSM_RRResult(Boolean isSuccess, String status, Id groupId) {
        this.isSuccess = isSuccess;
        this.status = status;
        this.groupId = groupId;
    }
}
