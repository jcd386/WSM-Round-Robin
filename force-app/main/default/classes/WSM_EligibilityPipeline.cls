/**
 * Runs the ordered gate chain (Active → Out of Office → Period Capacity → Capacity
 * Queries) against one member and returns the first skip reason encountered, or null if
 * the member clears every gate.
 *
 * Capacity Queries run last because they are the most specific and their skip reasons are
 * the most expensive to read: "Inactive" is more useful than "At capacity on Active
 * Employers (38/20)" when both are true.
 */
public inherited sharing class WSM_EligibilityPipeline {

    private List<WSM_EligibilityRule> rules;

    public WSM_EligibilityPipeline(List<WSM_EligibilityRule> rules) {
        this.rules = rules;
    }

    public static WSM_EligibilityPipeline defaultPipeline() {
        return new WSM_EligibilityPipeline(new List<WSM_EligibilityRule>{
            new WSM_ActiveRule(),
            new WSM_OutOfOfficeRule(),
            new WSM_CapacityRule(),
            new WSM_CapacityQueryRule()
        });
    }

    public String evaluate(WSM_MemberState member, WSM_GroupState grp, Date today) {
        for (WSM_EligibilityRule rule : rules) {
            String reason = rule.evaluate(member, grp, today);
            if (reason != null) {
                return reason;
            }
        }
        return null;
    }
}
