/** Flow-facing entry point: one request in, one routing decision out, per the invocable contract. */
public with sharing class WSM_RoundRobinInvocable {

    public class Request {
        @InvocableVariable(label='Group Id' description='Id of the Round Robin Group to assign from. Provide this or Group Developer Name.')
        public String groupId;

        @InvocableVariable(label='Group Developer Name' description='Stable developer-name key of the Round Robin Group. Preferred over Group Id so automation keeps working if the group is ever recreated.')
        public String groupDeveloperName;

        @InvocableVariable(label='Assigned Record Id' description='Id of the record being routed (e.g. the Lead or Case Id), stored on the audit log.')
        public String assignedRecordId;

        @InvocableVariable(label='Context' description='Free-text label identifying the calling flow, for troubleshooting.')
        public String context;
    }

    public class Result {
        @InvocableVariable(label='User Id' description='User this request was assigned to (member user, or the group fallback user). Blank when a fallback queue was used.')
        public Id userId;

        @InvocableVariable(label='Queue Id' description='Fallback queue that received this request. Only set on FALLBACK outcomes for groups configured with a fallback queue.')
        public Id queueId;

        @InvocableVariable(label='Owner Id' description='The Id to put in OwnerId: the assigned user, or the fallback queue when no user was eligible. Queues can only own queue-enabled objects like Leads and Cases.')
        public Id ownerId;

        @InvocableVariable(label='Member Id' description='Round Robin Member record that was selected. Blank on fallback/error outcomes.')
        public Id memberId;

        @InvocableVariable(label='Group Id' description='Round Robin Group this request resolved to.')
        public Id groupId;

        @InvocableVariable(label='Status' description='ASSIGNED, FALLBACK, NO_ELIGIBLE_MEMBERS, GROUP_NOT_FOUND, GROUP_INACTIVE, LOCK_TIMEOUT, or ERROR.')
        public String status;

        @InvocableVariable(label='Is Success' description='True when an assignee (member or fallback user) was returned.')
        public Boolean isSuccess;

        @InvocableVariable(label='Message' description='Human-readable detail, populated on non-Assigned outcomes.')
        public String message;

        @InvocableVariable(label='Log Id' description='Assignment Log record created for this request.')
        public Id logId;
    }

    @InvocableMethod(label='Round Robin: Get Assignee' description='Picks the next assignee from a WSM Round Robin Group and logs the decision.' category='WSM Round Robin')
    public static List<Result> getAssignee(List<Request> requests) {
        List<WSM_RRRequest> serviceRequests = new List<WSM_RRRequest>();
        for (Request req : requests) {
            WSM_RRRequest serviceRequest = new WSM_RRRequest();
            serviceRequest.groupId = safeId(req.groupId);
            serviceRequest.groupDeveloperName = req.groupDeveloperName;
            serviceRequest.assignedRecordId = req.assignedRecordId;
            serviceRequest.context = req.context;
            serviceRequests.add(serviceRequest);
        }

        List<WSM_RRResult> serviceResults = WSM_RoundRobinService.assign(serviceRequests);

        List<Result> results = new List<Result>();
        for (WSM_RRResult sr : serviceResults) {
            Result result = new Result();
            result.userId = sr.userId;
            result.queueId = sr.queueId;
            result.ownerId = sr.ownerId;
            result.memberId = sr.memberId;
            result.groupId = sr.groupId;
            result.status = sr.status;
            result.isSuccess = sr.isSuccess;
            result.message = sr.message;
            result.logId = sr.logId;
            results.add(result);
        }
        return results;
    }

    private static Id safeId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (System.StringException malformedId) {
            return null;
        }
    }
}
