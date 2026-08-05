/**
 * Runs the ordered gate chain (Active → Out of Office → Capacity, per the plan) against
 * one member and returns the first skip reason encountered, or null if the member
 * clears every gate.
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
            new WSM_CapacityRule()
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
