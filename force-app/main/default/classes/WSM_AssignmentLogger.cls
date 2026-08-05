/** Builds WSM_Assignment_Log__c rows and the human-readable skip-reason summary for Detail. */
public inherited sharing class WSM_AssignmentLogger {

    public static final String LOG_STATUS_ASSIGNED = 'Assigned';
    public static final String LOG_STATUS_FALLBACK = 'Fallback';
    public static final String LOG_STATUS_NO_ELIGIBLE_MEMBERS = 'No Eligible Members';
    public static final String LOG_STATUS_ERROR = 'Error';

    private static final Integer ALGORITHM_MAX_LENGTH = 40;
    private static final Integer ASSIGNED_RECORD_ID_MAX_LENGTH = 18;
    private static final Integer CONTEXT_MAX_LENGTH = 255;
    private static final Integer DETAIL_MAX_LENGTH = 2000;

    public static WSM_Assignment_Log__c buildLog(Id groupId, Id memberId, Id assignedUserId, String algorithm,
            String logStatus, WSM_RRRequest request, String detail) {
        WSM_Assignment_Log__c log = new WSM_Assignment_Log__c();
        log.WSM_Group__c = groupId;
        log.WSM_Member__c = memberId;
        log.WSM_Assigned_User__c = assignedUserId;
        log.WSM_Algorithm__c = truncate(algorithm, ALGORITHM_MAX_LENGTH);
        log.WSM_Status__c = logStatus;
        log.WSM_Assigned_Record_Id__c = truncate(request == null ? null : request.assignedRecordId, ASSIGNED_RECORD_ID_MAX_LENGTH);
        log.WSM_Context__c = truncate(request == null ? null : request.context, CONTEXT_MAX_LENGTH);
        log.WSM_Detail__c = truncate(detail, DETAIL_MAX_LENGTH);
        return log;
    }

    /** e.g. "Skipped 3: 2 at cap, 1 out of office". Returns null when nobody was skipped. */
    public static String buildSkipSummary(Map<Id, String> skipReasonByMemberId) {
        if (skipReasonByMemberId == null || skipReasonByMemberId.isEmpty()) {
            return null;
        }
        Map<String, Integer> countByCategory = new Map<String, Integer>();
        for (String reason : skipReasonByMemberId.values()) {
            String category = categoryFor(reason);
            Integer running = countByCategory.containsKey(category) ? countByCategory.get(category) : 0;
            countByCategory.put(category, running + 1);
        }
        List<String> parts = new List<String>();
        for (String category : countByCategory.keySet()) {
            parts.add(countByCategory.get(category) + ' ' + category);
        }
        return 'Skipped ' + skipReasonByMemberId.size() + ': ' + String.join(parts, ', ');
    }

    private static String categoryFor(String reason) {
        if (reason == 'Inactive') {
            return 'inactive';
        }
        if (reason != null && reason.startsWith('At capacity')) {
            return 'at cap';
        }
        if (reason != null && reason.startsWith('Out of office')) {
            return 'out of office';
        }
        return 'ineligible';
    }

    private static String truncate(String value, Integer maxLength) {
        if (String.isBlank(value)) {
            return value;
        }
        return value.length() > maxLength ? value.substring(0, maxLength) : value;
    }
}
