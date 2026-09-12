/**
 * Compiles admin-authored Capacity Query config into a validated aggregate SOQL string
 * plus a bind map. This is the package's only dynamic SOQL, so the whole injection
 * surface lives in this one class.
 *
 * The rules that make it safe, all enforced here:
 *   1. Object and field names are never concatenated from admin input. Every name is
 *      resolved through Schema describe and the DESCRIBE'S OWN getName() is what goes
 *      into the query. A name that does not resolve makes the definition invalid and no
 *      query is ever built from it.
 *   2. Operators come from a restricted picklist and are mapped to hardcoded SOQL
 *      fragments by operatorFragment(). Admin text can never become an operator.
 *   3. Values are always bind variables, typed by the target field's DisplayType.
 *      Nothing is inlined.
 *   4. Date literals are the sole exception to (3), because SOQL cannot bind them. They
 *      are matched against a closed whitelist regex before being inlined, so only
 *      strings of the exact shape LAST_N_DAYS:30 or THIS_MONTH can appear.
 *   5. Filter Logic is tokenized and every token must be an integer that matches a real
 *      child filter, or AND, OR, '(' or ')'. Anything else invalidates the definition.
 *   6. The SELECT list is fixed: COUNT(Id) plus the group-by keys. The builder has no
 *      code path that can emit a field value from the counted records, so a
 *      misconfiguration cannot turn a count into a data read.
 */
public inherited sharing class WSM_CapacityQueryBuilder {

    public static final String SRC_LITERAL = 'Literal';
    public static final String SRC_RELATIVE_DATE = 'Relative Date';
    public static final String SRC_ROUTED_FIELD = 'Routed Record Field';

    public static final String OWNER_BIND = 'ownerIds';
    public static final String PARAM_BIND = 'paramValues';
    public static final String GROUP_KEY_ALIAS = 'gkey';
    public static final String PARAM_KEY_ALIAS = 'pkey';
    public static final String COUNT_ALIAS = 'cnt';

    private static final String DEFAULT_OWNER_FIELD = 'OwnerId';
    private static final Integer MAX_IN_VALUES = 100;

    /** Fixed Salesforce date literals. Anything not here and not matching the N-pattern is rejected. */
    private static final Set<String> DATE_LITERALS = new Set<String>{
        'YESTERDAY', 'TODAY', 'TOMORROW',
        'LAST_WEEK', 'THIS_WEEK', 'NEXT_WEEK',
        'LAST_MONTH', 'THIS_MONTH', 'NEXT_MONTH',
        'LAST_90_DAYS', 'NEXT_90_DAYS',
        'THIS_QUARTER', 'LAST_QUARTER', 'NEXT_QUARTER',
        'THIS_YEAR', 'LAST_YEAR', 'NEXT_YEAR',
        'THIS_FISCAL_QUARTER', 'LAST_FISCAL_QUARTER', 'NEXT_FISCAL_QUARTER',
        'THIS_FISCAL_YEAR', 'LAST_FISCAL_YEAR', 'NEXT_FISCAL_YEAR'
    };

    /** Parameterized date literals, e.g. LAST_N_DAYS:30. The number is bounded to 4 digits. */
    private static final String DATE_LITERAL_N_PATTERN =
        '^(LAST|NEXT)_N_(DAYS|WEEKS|MONTHS|QUARTERS|YEARS|FISCAL_QUARTERS|FISCAL_YEARS):[0-9]{1,4}$';

    /** Operators whose value must be a list. */
    private static final Set<String> LIST_OPERATORS = new Set<String>{ 'in', 'not in', 'includes', 'excludes' };

    /** Operators that ignore Value entirely. */
    private static final Set<String> NO_VALUE_OPERATORS = new Set<String>{ 'is null', 'is not null' };

    /** Operators that compile to LIKE, so the value has to be text. */
    private static final Set<String> LIKE_OPERATORS = new Set<String>{ 'starts with', 'contains', 'ends with' };

    /** Operators that only mean anything on a multi-select picklist. */
    private static final Set<String> MULTIPICKLIST_OPERATORS = new Set<String>{ 'includes', 'excludes' };

    /** Field types a LIKE comparison is allowed against. */
    private static final Set<DisplayType> TEXTUAL_TYPES = new Set<DisplayType>{
        DisplayType.STRING, DisplayType.TEXTAREA, DisplayType.PICKLIST, DisplayType.MULTIPICKLIST,
        DisplayType.EMAIL, DisplayType.PHONE, DisplayType.URL, DisplayType.ENCRYPTEDSTRING
    };

    // ---------------------------------------------------------------- compile

    /**
     * Resolves one config row and its filters against the schema. Always returns a def:
     * on any problem the def comes back with isValid = false and a reason an admin can
     * act on, because a bad capacity query must degrade to a logged warning rather than
     * breaking assignment for everyone.
     */
    public static WSM_CapacityQueryDef compile(WSM_Capacity_Query__c config, List<WSM_Capacity_Filter__c> filters) {
        WSM_CapacityQueryDef def = new WSM_CapacityQueryDef(config, filters);
        if (config == null) {
            return invalid(def, 'No configuration row.');
        }

        SObjectType targetType = resolveType(config.WSM_Object__c);
        if (targetType == null) {
            return invalid(def, 'Object \'' + config.WSM_Object__c + '\' does not exist or is not accessible.');
        }
        DescribeSObjectResult targetDescribe = targetType.getDescribe();
        if (!targetDescribe.isQueryable()) {
            return invalid(def, 'Object \'' + targetDescribe.getName() + '\' is not queryable.');
        }
        def.objectName = targetDescribe.getName();

        // Seed the field cache here so the binds() and fragmentFor() passes that follow
        // reuse this map instead of paying for another describe.
        String objectKey = def.objectName.toLowerCase();
        if (!fieldMapCache.containsKey(objectKey)) {
            fieldMapCache.put(objectKey, targetDescribe.fields.getMap());
        }
        Map<String, SObjectField> targetFields = fieldMapCache.get(objectKey);

        String ownerFieldInput = String.isBlank(config.WSM_Owner_Field__c)
            ? DEFAULT_OWNER_FIELD
            : config.WSM_Owner_Field__c.trim();
        SObjectField ownerField = targetFields.get(ownerFieldInput.toLowerCase());
        if (ownerField == null) {
            return invalid(def, 'Owner field \'' + ownerFieldInput + '\' does not exist on ' + def.objectName + '.');
        }
        DescribeFieldResult ownerDescribe = ownerField.getDescribe();
        if (!ownerDescribe.isFilterable() || !ownerDescribe.isGroupable()) {
            return invalid(def, 'Owner field \'' + ownerDescribe.getName() + '\' cannot be filtered and grouped.');
        }
        DisplayType ownerKind = ownerDescribe.getType();
        if (ownerKind != DisplayType.ID && ownerKind != DisplayType.REFERENCE && ownerKind != DisplayType.STRING) {
            return invalid(def, 'Owner field \'' + ownerDescribe.getName() + '\' must hold User Ids.');
        }
        def.ownerFieldName = ownerDescribe.getName();

        if (def.filters.isEmpty()) {
            return invalid(def, 'Add at least one filter, otherwise this counts every record on the object.');
        }

        Set<Decimal> seenNumbers = new Set<Decimal>();
        Integer routedFilterCount = 0;
        for (WSM_Capacity_Filter__c filter : def.filters) {
            if (filter.WSM_Filter_Number__c == null) {
                return invalid(def, 'Every filter needs a Filter Number.');
            }
            if (seenNumbers.contains(filter.WSM_Filter_Number__c)) {
                return invalid(def, 'Filter Number ' + filter.WSM_Filter_Number__c.intValue() + ' is used twice.');
            }
            seenNumbers.add(filter.WSM_Filter_Number__c);

            String problem = validateFilter(def, filter, targetFields, targetDescribe.getName());
            if (problem != null) {
                return invalid(def, 'Filter ' + filter.WSM_Filter_Number__c.intValue() + ': ' + problem);
            }
            if (filter.WSM_Value_Source__c == SRC_ROUTED_FIELD) {
                routedFilterCount++;
            }
        }

        if (routedFilterCount > 1) {
            return invalid(def, 'Only one filter may read from the routed record. Split the rest into separate capacity queries.');
        }

        String logicProblem = validateLogic(config.WSM_Filter_Logic__c, seenNumbers);
        if (logicProblem != null) {
            return invalid(def, 'Filter Logic: ' + logicProblem);
        }

        if (def.isCap && def.cap == null) {
            return invalid(def, 'Role includes Cap but no Cap number is set.');
        }
        if (def.hasFloor && def.floor < 0) {
            return invalid(def, 'Floor cannot be negative.');
        }
        if (def.hasFloor && def.cap != null && def.floor >= def.cap) {
            return invalid(def, 'Floor (' + def.floor + ') must be lower than Cap (' + def.cap
                + '). Otherwise a member below the floor would be prioritised and blocked at the same time.');
        }
        if (!def.isCap && !def.isLoadMetric) {
            return invalid(def, 'Role must be Cap, Load Metric, or Cap and Load Metric.');
        }

        def.isValid = true;
        def.invalidReason = null;
        return def;
    }

    /**
     * Per-filter validation. Also records the routed-record wiring on the def, since that
     * is the one filter shape that changes the query's shape (extra group-by key).
     */
    private static String validateFilter(WSM_CapacityQueryDef def, WSM_Capacity_Filter__c filter,
            Map<String, SObjectField> targetFields, String targetName) {

        if (String.isBlank(filter.WSM_Field__c)) {
            return 'Field is required.';
        }
        SObjectField targetField = targetFields.get(filter.WSM_Field__c.trim().toLowerCase());
        if (targetField == null) {
            return 'field \'' + filter.WSM_Field__c + '\' does not exist on ' + targetName + '.';
        }
        DescribeFieldResult fieldDescribe = targetField.getDescribe();
        if (!fieldDescribe.isFilterable()) {
            return 'field \'' + fieldDescribe.getName() + '\' cannot be filtered.';
        }

        String operator = filter.WSM_Operator__c;
        if (operatorFragment(operator, 'x', false) == null) {
            return 'operator \'' + operator + '\' is not supported.';
        }

        String source = String.isBlank(filter.WSM_Value_Source__c) ? SRC_LITERAL : filter.WSM_Value_Source__c;

        if (NO_VALUE_OPERATORS.contains(operator)) {
            return null;
        }

        if (source == SRC_RELATIVE_DATE) {
            DisplayType kind = fieldDescribe.getType();
            if (kind != DisplayType.DATE && kind != DisplayType.DATETIME) {
                return 'Relative Date only works on Date or Date/Time fields; \'' + fieldDescribe.getName() + '\' is not one.';
            }
            if (!isWhitelistedDateLiteral(filter.WSM_Value__c)) {
                return 'value \'' + filter.WSM_Value__c + '\' is not a recognized date literal. Try LAST_N_DAYS:30 or THIS_MONTH.';
            }
            if (LIST_OPERATORS.contains(operator)) {
                return 'Relative Date cannot be used with ' + operator + '.';
            }
            return null;
        }

        if (source == SRC_ROUTED_FIELD) {
            if (operator != 'equals') {
                return 'Routed Record Field supports the equals operator only, because the count is grouped by that value.';
            }
            if (!fieldDescribe.isGroupable()) {
                return 'field \'' + fieldDescribe.getName() + '\' cannot be grouped, so it cannot take a value from the routed record.';
            }
            if (String.isBlank(filter.WSM_Routed_Record_Field__c)) {
                return 'Routed Record Field is required when Value Source is Routed Record Field.';
            }
            def.paramFieldName = fieldDescribe.getName();
            def.routedFieldName = filter.WSM_Routed_Record_Field__c.trim();
            return null;
        }

        if (String.isBlank(filter.WSM_Value__c)) {
            return 'Value is required for operator ' + operator + '.';
        }

        DisplayType literalKind = fieldDescribe.getType();
        if (LIKE_OPERATORS.contains(operator) && !TEXTUAL_TYPES.contains(literalKind)) {
            return operator + ' only works on text fields; \'' + fieldDescribe.getName() + '\' is a '
                + literalKind.name().toLowerCase() + '. Use equals instead.';
        }
        if (MULTIPICKLIST_OPERATORS.contains(operator) && literalKind != DisplayType.MULTIPICKLIST) {
            return operator + ' only works on multi-select picklists; \'' + fieldDescribe.getName() + '\' is not one.';
        }

        try {
            Object coerced = coerce(filter.WSM_Value__c, fieldDescribe, LIST_OPERATORS.contains(operator));
            if (coerced == null) {
                return 'value \'' + filter.WSM_Value__c + '\' could not be read as a '
                    + fieldDescribe.getType().name().toLowerCase() + '.';
            }
        } catch (Exception conversionFailure) {
            return 'value \'' + filter.WSM_Value__c + '\' could not be read as a '
                + fieldDescribe.getType().name().toLowerCase() + '.';
        }
        return null;
    }

    // ---------------------------------------------------------------- SOQL

    /**
     * Builds the aggregate query. Always COUNT(Id) grouped by the owner field, plus the
     * routed-record key when withParamKey is true. One query serves every member of the
     * group, so the footprint does not grow with pool size.
     */
    public static String toSoql(WSM_CapacityQueryDef def, Boolean withParamKey) {
        if (def == null || def.isValid != true) {
            return null;
        }
        Boolean useParam = withParamKey == true && def.needsRoutedValue;

        List<String> selectParts = new List<String>{ def.ownerFieldName + ' ' + GROUP_KEY_ALIAS };
        List<String> groupParts = new List<String>{ def.ownerFieldName };
        if (useParam) {
            selectParts.add(def.paramFieldName + ' ' + PARAM_KEY_ALIAS);
            groupParts.add(def.paramFieldName);
        }
        selectParts.add('COUNT(Id) ' + COUNT_ALIAS);

        List<String> whereParts = new List<String>{ def.ownerFieldName + ' IN :' + OWNER_BIND };
        if (useParam) {
            // Restricting to the values the caller already supplied keeps the grouped
            // result free of any value the caller did not already know.
            whereParts.add(def.paramFieldName + ' IN :' + PARAM_BIND);
        }
        String predicate = buildPredicate(def, useParam);
        if (String.isNotBlank(predicate)) {
            whereParts.add(predicate);
        }

        return 'SELECT ' + String.join(selectParts, ', ')
            + ' FROM ' + def.objectName
            + ' WHERE ' + String.join(whereParts, ' AND ')
            + ' GROUP BY ' + String.join(groupParts, ', ');
    }

    /**
     * Renders the filter rows into one parenthesized predicate, wired together by Filter
     * Logic. A routed-record filter contributes nothing here: it is already expressed as
     * the IN :paramValues restriction plus the group-by key.
     */
    private static String buildPredicate(WSM_CapacityQueryDef def, Boolean useParam) {
        Map<Integer, String> fragmentByNumber = new Map<Integer, String>();
        for (WSM_Capacity_Filter__c filter : def.filters) {
            Integer filterNumber = filter.WSM_Filter_Number__c.intValue();
            if (filter.WSM_Value_Source__c == SRC_ROUTED_FIELD) {
                fragmentByNumber.put(filterNumber, null);
                continue;
            }
            fragmentByNumber.put(filterNumber, fragmentFor(def, filter));
        }

        String logic = def.record.WSM_Filter_Logic__c;
        if (String.isBlank(logic)) {
            List<String> parts = new List<String>();
            List<Integer> orderedNumbers = new List<Integer>(fragmentByNumber.keySet());
            orderedNumbers.sort();
            for (Integer filterNumber : orderedNumbers) {
                if (fragmentByNumber.get(filterNumber) != null) {
                    parts.add(fragmentByNumber.get(filterNumber));
                }
            }
            return parts.isEmpty() ? null : '(' + String.join(parts, ' AND ') + ')';
        }
        return '(' + renderLogic(logic, fragmentByNumber) + ')';
    }

    /**
     * Substitutes fragments into the tokenized logic string. A routed-record filter's slot
     * renders as TRUE so the surrounding AND/OR shape is preserved without emitting a
     * duplicate predicate for a restriction the WHERE clause already carries.
     */
    private static String renderLogic(String logic, Map<Integer, String> fragmentByNumber) {
        List<String> out = new List<String>();
        for (String token : tokenize(logic)) {
            if (token == '(' || token == ')' || token == 'AND' || token == 'OR') {
                out.add(token);
                continue;
            }
            String fragment = fragmentByNumber.get(Integer.valueOf(token));
            out.add(fragment == null ? 'TRUE' : fragment);
        }
        return String.join(out, ' ');
    }

    /** Maps one filter row to its SOQL fragment. Operator text never reaches the output. */
    private static String fragmentFor(WSM_CapacityQueryDef def, WSM_Capacity_Filter__c filter) {
        String fieldName = resolveFieldName(def.objectName, filter.WSM_Field__c);
        String operator = filter.WSM_Operator__c;
        String source = String.isBlank(filter.WSM_Value_Source__c) ? SRC_LITERAL : filter.WSM_Value_Source__c;

        if (NO_VALUE_OPERATORS.contains(operator)) {
            return operatorFragment(operator, fieldName, false);
        }
        if (source == SRC_RELATIVE_DATE) {
            // Safe to inline: isWhitelistedDateLiteral() has already matched the value
            // against a closed set and a bounded numeric pattern, and SOQL cannot bind
            // a date literal.
            return operatorFragment(operator, fieldName, true)
                .replace('{literal}', filter.WSM_Value__c.trim().toUpperCase());
        }
        return operatorFragment(operator, fieldName, false)
            .replace('{bind}', ':' + bindName(filter));
    }

    /**
     * The complete operator whitelist. Returns null for anything not on it, which is what
     * validateFilter() uses to reject unsupported operators before a query exists.
     * useLiteral swaps the bind placeholder for a date-literal placeholder.
     */
    private static String operatorFragment(String operator, String fieldName, Boolean useLiteral) {
        String rhs = useLiteral == true ? '{literal}' : '{bind}';
        if (operator == 'equals') {
            return fieldName + ' = ' + rhs;
        }
        if (operator == 'not equals') {
            return fieldName + ' != ' + rhs;
        }
        if (operator == 'less than') {
            return fieldName + ' < ' + rhs;
        }
        if (operator == 'less or equal') {
            return fieldName + ' <= ' + rhs;
        }
        if (operator == 'greater than') {
            return fieldName + ' > ' + rhs;
        }
        if (operator == 'greater or equal') {
            return fieldName + ' >= ' + rhs;
        }
        if (operator == 'in') {
            return fieldName + ' IN ' + rhs;
        }
        if (operator == 'not in') {
            return fieldName + ' NOT IN ' + rhs;
        }
        if (operator == 'starts with' || operator == 'contains' || operator == 'ends with') {
            return fieldName + ' LIKE ' + rhs;
        }
        if (operator == 'includes') {
            return fieldName + ' INCLUDES ' + rhs;
        }
        if (operator == 'excludes') {
            return fieldName + ' EXCLUDES ' + rhs;
        }
        if (operator == 'is null') {
            return fieldName + ' = null';
        }
        if (operator == 'is not null') {
            return fieldName + ' != null';
        }
        return null;
    }

    // ---------------------------------------------------------------- binds

    /**
     * Every value the query needs, keyed by bind name. Built fresh per call so the same
     * compiled def can serve different owner sets and routed-value sets.
     */
    public static Map<String, Object> binds(WSM_CapacityQueryDef def, Set<Id> ownerIds, Set<Object> paramValues) {
        Map<String, Object> bindMap = new Map<String, Object>();
        bindMap.put(OWNER_BIND, new List<Id>(ownerIds == null ? new Set<Id>() : ownerIds));
        if (def.needsRoutedValue) {
            bindMap.put(PARAM_BIND, typedValueList(def, paramValues));
        }
        for (WSM_Capacity_Filter__c filter : def.filters) {
            String source = String.isBlank(filter.WSM_Value_Source__c) ? SRC_LITERAL : filter.WSM_Value_Source__c;
            if (source != SRC_LITERAL || NO_VALUE_OPERATORS.contains(filter.WSM_Operator__c)) {
                continue;
            }
            DescribeFieldResult fieldDescribe = describeField(def.objectName, filter.WSM_Field__c);
            if (fieldDescribe == null) {
                continue;
            }
            Object value = coerce(filter.WSM_Value__c, fieldDescribe, LIST_OPERATORS.contains(filter.WSM_Operator__c));
            value = applyLikeWrapping(filter.WSM_Operator__c, value);
            bindMap.put(bindName(filter), value);
        }
        return bindMap;
    }

    /**
     * Puts the routed-record values into a list of the param field's own concrete type.
     * A bare List<Object> is not reliably bindable into an IN clause, and when the bind
     * fails the whole capacity query degrades to "unevaluated" and silently stops capping
     * anyone, which is the worst possible failure for a cap. The values arriving here came
     * from SObject.get() so they are already the right runtime type; this only gives them
     * a typed container.
     */
    @TestVisible
    private static Object typedValueList(WSM_CapacityQueryDef def, Set<Object> paramValues) {
        Set<Object> values = paramValues == null ? new Set<Object>() : paramValues;
        DescribeFieldResult fieldDescribe = describeField(def.objectName, def.paramFieldName);
        DisplayType kind = fieldDescribe == null ? DisplayType.STRING : fieldDescribe.getType();

        if (kind == DisplayType.DATE) {
            List<Date> typed = new List<Date>();
            for (Object value : values) {
                typed.add((Date) value);
            }
            return typed;
        }
        if (kind == DisplayType.DATETIME) {
            List<Datetime> typed = new List<Datetime>();
            for (Object value : values) {
                typed.add((Datetime) value);
            }
            return typed;
        }
        if (kind == DisplayType.ID || kind == DisplayType.REFERENCE) {
            List<Id> typed = new List<Id>();
            for (Object value : values) {
                typed.add((Id) value);
            }
            return typed;
        }
        if (kind == DisplayType.BOOLEAN) {
            List<Boolean> typed = new List<Boolean>();
            for (Object value : values) {
                typed.add((Boolean) value);
            }
            return typed;
        }
        if (kind == DisplayType.INTEGER || kind == DisplayType.LONG || kind == DisplayType.CURRENCY
                || kind == DisplayType.DOUBLE || kind == DisplayType.PERCENT) {
            List<Decimal> typed = new List<Decimal>();
            for (Object value : values) {
                typed.add((Decimal) value);
            }
            return typed;
        }
        List<String> typed = new List<String>();
        for (Object value : values) {
            typed.add(String.valueOf(value));
        }
        return typed;
    }

    /** LIKE operators carry their wildcards in the bound value, never in the query string. */
    private static Object applyLikeWrapping(String operator, Object value) {
        if (!(value instanceof String)) {
            return value;
        }
        String text = (String) value;
        if (operator == 'starts with') {
            return escapeLike(text) + '%';
        }
        if (operator == 'ends with') {
            return '%' + escapeLike(text);
        }
        if (operator == 'contains') {
            return '%' + escapeLike(text) + '%';
        }
        return value;
    }

    /** Neutralizes wildcards inside an admin-supplied LIKE value so it matches literally. */
    private static String escapeLike(String text) {
        return text.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_');
    }

    private static String bindName(WSM_Capacity_Filter__c filter) {
        return 'b' + filter.WSM_Filter_Number__c.intValue();
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Converts an admin-typed string to the field's runtime type. Returns a List for the
     * list operators. Throws on unparseable input, which validateFilter() catches and
     * turns into a readable reason.
     */
    @TestVisible
    private static Object coerce(String raw, DescribeFieldResult fieldDescribe, Boolean asList) {
        if (raw == null) {
            return null;
        }
        if (asList) {
            List<Object> values = new List<Object>();
            for (String part : raw.split(',')) {
                String trimmed = part.trim();
                if (String.isNotBlank(trimmed)) {
                    values.add(coerceScalar(trimmed, fieldDescribe));
                }
                if (values.size() > MAX_IN_VALUES) {
                    throw new WSM_RoundRobinException('Too many values; the limit is ' + MAX_IN_VALUES + '.');
                }
            }
            return values;
        }
        return coerceScalar(raw.trim(), fieldDescribe);
    }

    private static Object coerceScalar(String raw, DescribeFieldResult fieldDescribe) {
        DisplayType kind = fieldDescribe.getType();
        if (kind == DisplayType.BOOLEAN) {
            if (raw.equalsIgnoreCase('true')) {
                return true;
            }
            if (raw.equalsIgnoreCase('false')) {
                return false;
            }
            throw new WSM_RoundRobinException('Expected true or false.');
        }
        if (kind == DisplayType.INTEGER) {
            return Integer.valueOf(raw);
        }
        if (kind == DisplayType.LONG) {
            return Long.valueOf(raw);
        }
        if (kind == DisplayType.CURRENCY || kind == DisplayType.DOUBLE || kind == DisplayType.PERCENT) {
            return Decimal.valueOf(raw);
        }
        if (kind == DisplayType.DATE) {
            return Date.valueOf(raw);
        }
        if (kind == DisplayType.DATETIME) {
            return raw.contains(' ') ? Datetime.valueOf(raw) : Datetime.newInstance(Date.valueOf(raw), Time.newInstance(0, 0, 0, 0));
        }
        if (kind == DisplayType.ID || kind == DisplayType.REFERENCE) {
            return Id.valueOf(raw);
        }
        return raw;
    }

    @TestVisible
    private static Boolean isWhitelistedDateLiteral(String value) {
        if (String.isBlank(value)) {
            return false;
        }
        String candidate = value.trim().toUpperCase();
        if (DATE_LITERALS.contains(candidate)) {
            return true;
        }
        return Pattern.matches(DATE_LITERAL_N_PATTERN, candidate);
    }

    /**
     * Accepts only integers, AND, OR and parentheses, and every integer must name a real
     * filter. Also checks parenthesis balance so a malformed string is caught here rather
     * than becoming a QueryException at runtime.
     */
    @TestVisible
    private static String validateLogic(String logic, Set<Decimal> validNumbers) {
        if (String.isBlank(logic)) {
            return null;
        }
        List<String> tokens = tokenize(logic);
        if (tokens == null) {
            return 'only filter numbers, AND, OR and parentheses are allowed.';
        }
        Integer depth = 0;
        Set<Decimal> referenced = new Set<Decimal>();
        for (String token : tokens) {
            if (token == '(') {
                depth++;
            } else if (token == ')') {
                depth--;
                if (depth < 0) {
                    return 'unbalanced parentheses.';
                }
            } else if (token != 'AND' && token != 'OR') {
                Decimal tokenNumber = Decimal.valueOf(token);
                if (!validNumbers.contains(tokenNumber)) {
                    return 'refers to filter ' + token + ', which does not exist.';
                }
                referenced.add(tokenNumber);
            }
        }
        if (depth != 0) {
            return 'unbalanced parentheses.';
        }
        if (referenced.isEmpty()) {
            return 'does not reference any filter.';
        }
        for (Decimal validNumber : validNumbers) {
            if (!referenced.contains(validNumber)) {
                return 'filter ' + validNumber.intValue() + ' is never referenced. Remove it or add it to the logic.';
            }
        }
        return null;
    }

    /** Returns null when the string contains anything outside the allowed token set. */
    @TestVisible
    private static List<String> tokenize(String logic) {
        List<String> tokens = new List<String>();
        String padded = logic.toUpperCase().replace('(', ' ( ').replace(')', ' ) ');
        for (String rawToken : padded.split('\\s+')) {
            String token = rawToken.trim();
            if (String.isBlank(token)) {
                continue;
            }
            if (token == '(' || token == ')' || token == 'AND' || token == 'OR') {
                tokens.add(token);
                continue;
            }
            if (!Pattern.matches('^[0-9]{1,3}$', token)) {
                return null;
            }
            tokens.add(token);
        }
        return tokens;
    }

    /**
     * Resolves a routed-record field against the object the caller's record actually is,
     * which is only knowable at runtime from the record Id. Returns the schema's own field
     * name, or null when the config names a field that object does not have. The engine
     * treats null as "this capacity query cannot be evaluated for this record" and warns
     * rather than guessing.
     */
    public static String resolveRoutedFieldName(SObjectType routedType, String fieldName) {
        if (routedType == null || String.isBlank(fieldName)) {
            return null;
        }
        SObjectField field = routedType.getDescribe().fields.getMap().get(fieldName.trim().toLowerCase());
        if (field == null) {
            return null;
        }
        DescribeFieldResult fieldDescribe = field.getDescribe();
        return fieldDescribe.isAccessible() ? fieldDescribe.getName() : null;
    }

    /**
     * Transaction-scoped describe caches. Schema.getGlobalDescribe() is a genuinely
     * expensive CPU call, and compiling plus binding a handful of capacity queries hits
     * it a couple of dozen times per assign() without this. Both caches are per
     * transaction, so a schema change between transactions is picked up normally.
     */
    private static Map<String, SObjectType> typeCache = new Map<String, SObjectType>();
    private static Map<String, Map<String, SObjectField>> fieldMapCache = new Map<String, Map<String, SObjectField>>();

    private static SObjectType resolveType(String objectName) {
        if (String.isBlank(objectName)) {
            return null;
        }
        String key = objectName.trim().toLowerCase();
        if (!typeCache.containsKey(key)) {
            typeCache.put(key, Schema.getGlobalDescribe().get(key));
        }
        return typeCache.get(key);
    }

    private static DescribeFieldResult describeField(String objectName, String fieldName) {
        SObjectType objectType = resolveType(objectName);
        if (objectType == null || String.isBlank(fieldName)) {
            return null;
        }
        String objectKey = objectName.trim().toLowerCase();
        if (!fieldMapCache.containsKey(objectKey)) {
            fieldMapCache.put(objectKey, objectType.getDescribe().fields.getMap());
        }
        SObjectField field = fieldMapCache.get(objectKey).get(fieldName.trim().toLowerCase());
        return field == null ? null : field.getDescribe();
    }

    /** Always the schema's own name, never the admin's typed casing. */
    private static String resolveFieldName(String objectName, String fieldName) {
        DescribeFieldResult fieldDescribe = describeField(objectName, fieldName);
        return fieldDescribe == null ? null : fieldDescribe.getName();
    }

    private static WSM_CapacityQueryDef invalid(WSM_CapacityQueryDef def, String reason) {
        def.isValid = false;
        def.invalidReason = reason;
        return def;
    }
}
