/**
 * One Capacity Query compiled against the org schema: the config rows plus the
 * schema-resolved names the SOQL will actually use, plus a validity verdict. Built once
 * per group load by WSM_CapacityQueryBuilder.compile() and then read-only, so the same
 * compiled definition serves the locked assign() path and the lock-free preview().
 *
 * Nothing here holds a value an admin typed as part of a query string. objectName,
 * ownerFieldName and paramFieldName are taken from the schema describe's own getName(),
 * which is why an invalid config can only ever produce isValid = false and never a
 * malformed or injected query.
 */
public class WSM_CapacityQueryDef {

    public static final String ROLE_CAP = 'Cap';
    public static final String ROLE_LOAD = 'Load Metric';
    public static final String ROLE_BOTH = 'Cap and Load Metric';

    public WSM_Capacity_Query__c record;
    public List<WSM_Capacity_Filter__c> filters;

    /** False when the config could not be resolved against the schema; see invalidReason. */
    public Boolean isValid;
    public String invalidReason;

    /** Schema-resolved names. Populated only when isValid. */
    public String objectName;
    public String ownerFieldName;

    /**
     * Set only when one filter draws its value off the record being routed. paramFieldName
     * is the field on the counted object; routedFieldName is the field on the routed
     * record that supplies the value. Both schema-resolved.
     */
    public String paramFieldName;
    public String routedFieldName;
    public String routedObjectName;

    public WSM_CapacityQueryDef(WSM_Capacity_Query__c record, List<WSM_Capacity_Filter__c> filters) {
        this.record = record;
        this.filters = filters == null ? new List<WSM_Capacity_Filter__c>() : filters;
        this.isValid = false;
    }

    public Id configId {
        get { return record == null ? null : record.Id; }
    }

    /** Falls back to the autonumber name so a skip reason is never blank. */
    public String label {
        get {
            if (record == null) {
                return 'Capacity query';
            }
            return String.isNotBlank(record.WSM_Label__c) ? record.WSM_Label__c : record.Name;
        }
    }

    public Boolean isCap {
        get {
            String role = record == null ? null : record.WSM_Role__c;
            return role == ROLE_CAP || role == ROLE_BOTH;
        }
    }

    public Boolean isLoadMetric {
        get {
            String role = record == null ? null : record.WSM_Role__c;
            return role == ROLE_LOAD || role == ROLE_BOTH;
        }
    }

    /** Null means "no cap configured", which leaves a Cap-role row permissive by design. */
    public Integer cap {
        get {
            if (record == null || record.WSM_Cap__c == null) {
                return null;
            }
            return record.WSM_Cap__c.intValue();
        }
    }

    /**
     * Minimum this count should reach. Null means no floor. Unlike cap this never blocks
     * anyone: it promotes whoever is under it ahead of whoever is not, inside their tier.
     */
    public Integer floor {
        get {
            if (record == null || record.WSM_Floor__c == null) {
                return null;
            }
            return record.WSM_Floor__c.intValue();
        }
    }

    public Boolean hasFloor {
        get { return floor != null; }
    }

    /** Defaults to 1 so a blank Load Weight behaves as "counts once". */
    public Decimal loadWeight {
        get {
            if (record == null || record.WSM_Load_Weight__c == null) {
                return 1;
            }
            return record.WSM_Load_Weight__c;
        }
    }

    /** True when this count cannot be built without a value off the routed record. */
    public Boolean needsRoutedValue {
        get { return paramFieldName != null; }
    }
}
