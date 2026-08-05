/**
 * Blocked when today >= OOO Start AND today < OOO Return (the return day itself is
 * eligible). A blank Start means the member was never marked OOO. A Start with a blank
 * Return means OOO indefinitely from that date — there's no way to represent "OOO
 * forever" other than leaving Return blank, so that's treated as an open-ended window
 * rather than a data error.
 */
public inherited sharing class WSM_OutOfOfficeRule implements WSM_EligibilityRule {

    public String evaluate(WSM_MemberState member, WSM_GroupState grp, Date today) {
        Date startDate = member.record.WSM_OOO_Start_Date__c;
        if (startDate == null || today < startDate) {
            return null;
        }
        Date returnDate = member.record.WSM_OOO_Return_Date__c;
        if (returnDate == null) {
            return 'Out of office (no return date set)';
        }
        if (today < returnDate) {
            return 'Out of office until ' + String.valueOf(returnDate);
        }
        return null;
    }
}
