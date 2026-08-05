/**
 * One assignment ask passed into WSM_RoundRobinEngine/Service. Callers supply either
 * groupId or groupDeveloperName (Id wins if both are set) plus optional context for the
 * audit log.
 */
public class WSM_RRRequest {

    public Id groupId;
    public String groupDeveloperName;
    public String assignedRecordId;
    public String context;

    public WSM_RRRequest() {
    }

    public WSM_RRRequest(Id groupId) {
        this.groupId = groupId;
    }

    public WSM_RRRequest(Id groupId, String assignedRecordId, String context) {
        this.groupId = groupId;
        this.assignedRecordId = assignedRecordId;
        this.context = context;
    }

    public static WSM_RRRequest byDeveloperName(String groupDeveloperName) {
        WSM_RRRequest req = new WSM_RRRequest();
        req.groupDeveloperName = groupDeveloperName;
        return req;
    }
}
