/**
 * Public, `with sharing` facade over WSM_RoundRobinEngine, the only entry point other
 * Apex code (controllers, invocables) should call directly. Static because the
 * service is stateless: every call builds a fresh WSM_RoundRobinEngine and delegates
 * straight through. The engine field stays swappable (@TestVisible) even though it's
 * static, in case a future test needs to stub it.
 */
public with sharing class WSM_RoundRobinService {

    @TestVisible
    private static WSM_RoundRobinEngine engine = new WSM_RoundRobinEngine();

    public static List<WSM_RRResult> assign(List<WSM_RRRequest> requests) {
        return engine.assign(requests);
    }

    public static WSM_RRResult assign(Id groupId) {
        return firstResult(engine.assign(new List<WSM_RRRequest>{ new WSM_RRRequest(groupId) }));
    }

    public static WSM_RRResult assignByDeveloperName(String developerName) {
        return firstResult(engine.assign(new List<WSM_RRRequest>{ WSM_RRRequest.byDeveloperName(developerName) }));
    }

    public static WSM_RRPreview preview(Id groupId) {
        return engine.preview(groupId);
    }

    private static WSM_RRResult firstResult(List<WSM_RRResult> results) {
        return results.isEmpty() ? null : results[0];
    }
}
