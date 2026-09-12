import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCapacityQueries from '@salesforce/apex/WSM_RR_AdminController.getCapacityQueries';
import saveCapacityQuery from '@salesforce/apex/WSM_RR_AdminController.saveCapacityQuery';
import validateCapacityQuery from '@salesforce/apex/WSM_RR_AdminController.validateCapacityQuery';
import deleteCapacityQuery from '@salesforce/apex/WSM_RR_AdminController.deleteCapacityQuery';
import describeCountableObjects from '@salesforce/apex/WSM_RR_AdminController.describeCountableObjects';
import describeFilterableFields from '@salesforce/apex/WSM_RR_AdminController.describeFilterableFields';
import { reduceErrorMessage, debounce } from 'c/wsmRrUtils';

const ROLE_CAP = 'Cap';
const ROLE_LOAD = 'Load Metric';
const ROLE_BOTH = 'Cap and Load Metric';

const ROLE_OPTIONS = [
    { value: ROLE_CAP, label: 'Cap' },
    { value: ROLE_LOAD, label: 'Load Metric' },
    { value: ROLE_BOTH, label: 'Cap and Load Metric' }
];

const SRC_LITERAL = 'Literal';
const SRC_RELATIVE_DATE = 'Relative Date';
const SRC_ROUTED_FIELD = 'Routed Record Field';

const OPERATOR_OPTIONS = [
    { value: 'equals', label: 'equals' },
    { value: 'not equals', label: 'not equals' },
    { value: 'less than', label: 'less than' },
    { value: 'less or equal', label: 'less or equal' },
    { value: 'greater than', label: 'greater than' },
    { value: 'greater or equal', label: 'greater or equal' },
    { value: 'in', label: 'in' },
    { value: 'not in', label: 'not in' },
    { value: 'starts with', label: 'starts with' },
    { value: 'contains', label: 'contains' },
    { value: 'ends with', label: 'ends with' },
    { value: 'includes', label: 'includes' },
    { value: 'excludes', label: 'excludes' },
    { value: 'is null', label: 'is null' },
    { value: 'is not null', label: 'is not null' }
];

const LIKE_OPERATORS = new Set(['starts with', 'contains', 'ends with']);
const MULTIPICKLIST_OPERATORS = new Set(['includes', 'excludes']);
const NO_VALUE_OPERATORS = new Set(['is null', 'is not null']);
const LIST_OPERATORS = new Set(['in', 'not in']);
const TEXTUAL_TYPES = new Set(['STRING', 'TEXTAREA', 'PICKLIST', 'MULTIPICKLIST', 'EMAIL', 'PHONE', 'URL']);
const OWNER_FIELD_TYPES = new Set(['ID', 'REFERENCE', 'STRING']);

const CUSTOM_N_SENTINEL = '__CUSTOM_N__';
const CUSTOM_N_PATTERN = /^LAST_N_(DAYS|WEEKS|MONTHS):(\d+)$/;

const RELATIVE_DATE_OPTIONS = [
    { value: 'TODAY', label: 'Today' },
    { value: 'YESTERDAY', label: 'Yesterday' },
    { value: 'THIS_WEEK', label: 'This week' },
    { value: 'LAST_WEEK', label: 'Last week' },
    { value: 'THIS_MONTH', label: 'This month' },
    { value: 'LAST_MONTH', label: 'Last month' },
    { value: 'LAST_90_DAYS', label: 'Last 90 days' },
    { value: 'THIS_QUARTER', label: 'This quarter' },
    { value: 'LAST_QUARTER', label: 'Last quarter' },
    { value: 'THIS_YEAR', label: 'This year' },
    { value: 'LAST_YEAR', label: 'Last year' },
    { value: CUSTOM_N_SENTINEL, label: 'A specific number back...' }
];

const CUSTOM_UNIT_OPTIONS = [
    { value: 'DAYS', label: 'Days' },
    { value: 'WEEKS', label: 'Weeks' },
    { value: 'MONTHS', label: 'Months' }
];

/**
 * Capacity tab: plain-language editor for Capacity Queries. Each one is "count records
 * where..." used as a hard cap, a load metric for Least Loaded, or both. Every edit
 * debounces a call to the same compiler the assignment engine uses, so an admin sees a
 * pass/fail verdict before anything is ever routed with it.
 */
export default class WsmRrCapacityPanel extends LightningElement {
    @api algorithm;

    _groupId;
    @api
    get groupId() {
        return this._groupId;
    }
    set groupId(val) {
        this._groupId = val;
        if (val) {
            this.loadQueries();
        }
    }

    isLoading = false;
    queries = [];
    objectOptions = [];
    fieldOptionsByObject = {};
    customUnitOptions = CUSTOM_UNIT_OPTIONS;

    showRemoveConfirm = false;
    removeTargetRowId = null;
    removeTargetRecordId = null;
    removeTargetLabel = '';

    _nextTempId = 1;
    _validateDebouncers = {};

    @wire(describeCountableObjects)
    wiredObjects({ data, error }) {
        if (data) {
            this.objectOptions = data.map((o) => ({ label: o.label, value: o.apiName }));
        } else if (error) {
            this.toastError('Could not load objects', error);
        }
    }

    // ------------------------------------------------------------------
    // Loading
    // ------------------------------------------------------------------

    async loadQueries(expandedIds) {
        this.isLoading = true;
        const expand = expandedIds || new Set();
        try {
            const rows = await getCapacityQueries({ groupId: this._groupId });
            this.queries = (rows || []).map((r) => this.toDraft(r, expand));
            const objects = [...new Set(this.queries.map((q) => q.objectName).filter((o) => !!o))];
            await Promise.all(objects.map((o) => this.ensureFieldsLoaded(o)));
        } catch (error) {
            this.toastError('Could not load capacity queries', error);
        } finally {
            this.isLoading = false;
        }
    }

    async ensureFieldsLoaded(objectName) {
        if (!objectName) {
            return;
        }
        const key = objectName.toLowerCase();
        if (this.fieldOptionsByObject[key]) {
            return;
        }
        try {
            const fields = await describeFilterableFields({ objectName });
            this.fieldOptionsByObject = { ...this.fieldOptionsByObject, [key]: fields || [] };
        } catch (error) {
            this.toastError('Could not load fields for ' + objectName, error);
        }
    }

    fieldsFor(objectName) {
        if (!objectName) {
            return [];
        }
        return this.fieldOptionsByObject[objectName.toLowerCase()] || [];
    }

    toDraft(row, expandIds) {
        const clientId = row.id || `new-${this._nextTempId++}`;
        return {
            id: row.id || null,
            clientId,
            label: row.label || '',
            objectName: row.objectName || '',
            ownerField: row.ownerField || 'OwnerId',
            role: row.role || ROLE_CAP,
            cap: row.cap != null ? row.cap : null,
            loadWeight: row.loadWeight != null ? row.loadWeight : 1,
            filterLogic: row.filterLogic || '',
            active: row.active !== false,
            sortOrder: row.sortOrder != null ? row.sortOrder : 0,
            description: row.description || '',
            filters: (row.filters || []).map((f) => this.toFilterDraft(f)),
            collapsed: !expandIds.has(row.id),
            valid: row.valid,
            invalidReason: row.invalidReason,
            validating: false,
            saving: false
        };
    }

    toFilterDraft(f) {
        return {
            clientId: f.id || `newf-${this._nextTempId++}`,
            id: f.id || null,
            filterNumber: f.filterNumber,
            fieldName: f.fieldName || '',
            operator: f.operator || 'equals',
            valueSource: f.valueSource || SRC_LITERAL,
            value: f.value || '',
            routedRecordField: f.routedRecordField || ''
        };
    }

    // ------------------------------------------------------------------
    // Row / filter mutation helpers
    // ------------------------------------------------------------------

    updateQuery(rowId, updater) {
        this.queries = this.queries.map((q) => (q.clientId === rowId ? { ...q, ...updater(q) } : q));
    }

    updateFilter(rowId, filterId, updater) {
        this.updateQuery(rowId, (q) => ({
            filters: q.filters.map((f) => (f.clientId === filterId ? { ...f, ...updater(f) } : f))
        }));
    }

    nextSortOrder() {
        return this.queries.reduce((max, q) => Math.max(max, q.sortOrder || 0), 0) + 10;
    }

    nextFilterNumber(q) {
        return q.filters.reduce((max, f) => Math.max(max, f.filterNumber || 0), 0) + 1;
    }

    // ------------------------------------------------------------------
    // Add / remove query
    // ------------------------------------------------------------------

    handleAddQuery() {
        const draft = {
            id: null,
            clientId: `new-${this._nextTempId++}`,
            label: '',
            objectName: '',
            ownerField: 'OwnerId',
            role: ROLE_CAP,
            cap: null,
            loadWeight: 1,
            filterLogic: '',
            active: true,
            sortOrder: this.nextSortOrder(),
            description: '',
            filters: [],
            collapsed: false,
            valid: null,
            invalidReason: null,
            validating: false,
            saving: false
        };
        this.queries = [...this.queries, draft];
    }

    handleDeleteClick(event) {
        const rowId = event.currentTarget.dataset.row;
        const q = this.queries.find((r) => r.clientId === rowId);
        if (!q) {
            return;
        }
        if (!q.id) {
            this.queries = this.queries.filter((r) => r.clientId !== rowId);
            return;
        }
        this.removeTargetRowId = rowId;
        this.removeTargetRecordId = q.id;
        this.removeTargetLabel = q.label || 'this count';
        this.showRemoveConfirm = true;
    }

    cancelRemove() {
        this.showRemoveConfirm = false;
        this.removeTargetRowId = null;
        this.removeTargetRecordId = null;
    }

    async confirmRemove() {
        const recordId = this.removeTargetRecordId;
        this.showRemoveConfirm = false;
        try {
            await deleteCapacityQuery({ capacityQueryId: recordId });
            this.toast('success', 'Count deleted');
            this.dispatchEvent(new CustomEvent('refresh'));
            await this.loadQueries();
        } catch (error) {
            this.toastError('Delete failed', error);
        } finally {
            this.removeTargetRowId = null;
            this.removeTargetRecordId = null;
        }
    }

    // ------------------------------------------------------------------
    // Collapse / expand
    // ------------------------------------------------------------------

    toggleCollapse(event) {
        const rowId = event.currentTarget.dataset.row;
        this.updateQuery(rowId, (q) => ({ collapsed: !q.collapsed }));
    }

    // ------------------------------------------------------------------
    // Row field handlers
    // ------------------------------------------------------------------

    handleLabelChange(event) {
        const rowId = event.currentTarget.dataset.row;
        const value = event.target.value;
        this.updateQuery(rowId, () => ({ label: value }));
        this.scheduleValidate(rowId);
    }

    handleObjectChange(event) {
        const rowId = event.currentTarget.dataset.row;
        const value = event.detail.value;
        this.updateQuery(rowId, () => ({ objectName: value, ownerField: 'OwnerId', filters: [], filterLogic: '' }));
        this.ensureFieldsLoaded(value);
        this.scheduleValidate(rowId);
    }

    handleOwnerFieldChange(event) {
        const rowId = event.currentTarget.dataset.row;
        const value = event.detail.value;
        this.updateQuery(rowId, () => ({ ownerField: value }));
        this.scheduleValidate(rowId);
    }

    handleRoleClick(event) {
        const rowId = event.currentTarget.dataset.row;
        const value = event.currentTarget.dataset.value;
        this.updateQuery(rowId, () => ({ role: value }));
        this.scheduleValidate(rowId);
    }

    handleCapChange(event) {
        const rowId = event.currentTarget.dataset.row;
        const raw = event.target.value;
        this.updateQuery(rowId, () => ({ cap: raw === '' ? null : Number(raw) }));
        this.scheduleValidate(rowId);
    }

    handleLoadWeightChange(event) {
        const rowId = event.currentTarget.dataset.row;
        const raw = event.target.value;
        this.updateQuery(rowId, () => ({ loadWeight: raw === '' ? null : Number(raw) }));
        this.scheduleValidate(rowId);
    }

    handleFilterLogicChange(event) {
        const rowId = event.currentTarget.dataset.row;
        const value = event.target.value;
        this.updateQuery(rowId, () => ({ filterLogic: value }));
        this.scheduleValidate(rowId);
    }

    handleActiveToggle(event) {
        const rowId = event.currentTarget.dataset.row;
        const checked = event.target.checked;
        this.updateQuery(rowId, () => ({ active: checked }));
        this.scheduleValidate(rowId);
    }

    handleSortOrderChange(event) {
        const rowId = event.currentTarget.dataset.row;
        const raw = event.target.value;
        this.updateQuery(rowId, () => ({ sortOrder: raw === '' ? 0 : Number(raw) }));
    }

    handleDescriptionChange(event) {
        const rowId = event.currentTarget.dataset.row;
        const value = event.target.value;
        this.updateQuery(rowId, () => ({ description: value }));
    }

    // ------------------------------------------------------------------
    // Filters
    // ------------------------------------------------------------------

    handleAddFilter(event) {
        const rowId = event.currentTarget.dataset.row;
        const q = this.queries.find((r) => r.clientId === rowId);
        if (!q) {
            return;
        }
        const newFilter = {
            clientId: `newf-${this._nextTempId++}`,
            id: null,
            filterNumber: this.nextFilterNumber(q),
            fieldName: '',
            operator: 'equals',
            valueSource: SRC_LITERAL,
            value: '',
            routedRecordField: ''
        };
        this.updateQuery(rowId, (row) => ({ filters: [...row.filters, newFilter] }));
        this.scheduleValidate(rowId);
    }

    handleRemoveFilter(event) {
        const { row: rowId, filter: filterId } = event.currentTarget.dataset;
        this.updateQuery(rowId, (q) => ({ filters: q.filters.filter((f) => f.clientId !== filterId) }));
        this.scheduleValidate(rowId);
    }

    handleFilterFieldChange(event) {
        const { row: rowId, filter: filterId } = event.currentTarget.dataset;
        const value = event.detail.value;
        this.updateFilter(rowId, filterId, () => ({
            fieldName: value,
            operator: 'equals',
            valueSource: SRC_LITERAL,
            value: '',
            routedRecordField: ''
        }));
        this.scheduleValidate(rowId);
    }

    handleFilterOperatorChange(event) {
        const { row: rowId, filter: filterId } = event.currentTarget.dataset;
        const value = event.detail.value;
        this.updateFilter(rowId, filterId, (f) => {
            const patch = { operator: value };
            if (NO_VALUE_OPERATORS.has(value)) {
                patch.value = '';
            }
            if (value !== 'equals' && f.valueSource === SRC_ROUTED_FIELD) {
                patch.valueSource = SRC_LITERAL;
                patch.value = '';
            }
            return patch;
        });
        this.scheduleValidate(rowId);
    }

    handleFilterValueSourceChange(event) {
        const { row: rowId, filter: filterId } = event.currentTarget.dataset;
        const value = event.detail.value;
        this.updateFilter(rowId, filterId, () => {
            const patch = { valueSource: value, value: '' };
            if (value === SRC_ROUTED_FIELD) {
                patch.operator = 'equals';
            } else {
                patch.routedRecordField = '';
            }
            return patch;
        });
        this.scheduleValidate(rowId);
    }

    handleFilterValueChange(event) {
        const { row: rowId, filter: filterId } = event.currentTarget.dataset;
        const value = event.target.value;
        this.updateFilter(rowId, filterId, () => ({ value }));
        this.scheduleValidate(rowId);
    }

    handleFilterRelativeChange(event) {
        const { row: rowId, filter: filterId } = event.currentTarget.dataset;
        const value = event.detail.value;
        if (value === CUSTOM_N_SENTINEL) {
            this.updateFilter(rowId, filterId, () => ({ value: 'LAST_N_DAYS:30' }));
        } else {
            this.updateFilter(rowId, filterId, () => ({ value }));
        }
        this.scheduleValidate(rowId);
    }

    handleFilterCustomNChange(event) {
        const { row: rowId, filter: filterId } = event.currentTarget.dataset;
        const raw = event.target.value;
        this.updateFilter(rowId, filterId, (f) => {
            const match = CUSTOM_N_PATTERN.exec(f.value || '');
            const unit = match ? match[1] : 'DAYS';
            const n = raw === '' ? '' : Math.max(1, Math.round(Number(raw)));
            return { value: n === '' ? '' : `LAST_N_${unit}:${n}` };
        });
        this.scheduleValidate(rowId);
    }

    handleFilterCustomUnitChange(event) {
        const { row: rowId, filter: filterId } = event.currentTarget.dataset;
        const unit = event.detail.value;
        this.updateFilter(rowId, filterId, (f) => {
            const match = CUSTOM_N_PATTERN.exec(f.value || '');
            const n = match ? match[2] : '30';
            return { value: `LAST_N_${unit}:${n}` };
        });
        this.scheduleValidate(rowId);
    }

    handleFilterRoutedFieldChange(event) {
        const { row: rowId, filter: filterId } = event.currentTarget.dataset;
        const value = event.target.value;
        this.updateFilter(rowId, filterId, () => ({ routedRecordField: value }));
        this.scheduleValidate(rowId);
    }

    // ------------------------------------------------------------------
    // Live validation
    // ------------------------------------------------------------------

    toPayload(q) {
        return {
            id: q.id,
            groupId: this._groupId,
            label: q.label,
            objectName: q.objectName,
            ownerField: q.ownerField,
            role: q.role,
            cap: q.cap,
            loadWeight: q.loadWeight,
            filterLogic: q.filterLogic,
            active: q.active,
            sortOrder: q.sortOrder,
            description: q.description,
            filters: q.filters.map((f, idx) => ({
                filterNumber: f.filterNumber || idx + 1,
                fieldName: f.fieldName,
                operator: f.operator,
                valueSource: f.valueSource,
                value: f.value,
                routedRecordField: f.routedRecordField
            }))
        };
    }

    scheduleValidate(rowId) {
        this.updateQuery(rowId, () => ({ validating: true }));
        if (!this._validateDebouncers[rowId]) {
            this._validateDebouncers[rowId] = debounce(() => this.runValidate(rowId), 400);
        }
        this._validateDebouncers[rowId]();
    }

    async runValidate(rowId) {
        const q = this.queries.find((r) => r.clientId === rowId);
        if (!q) {
            return;
        }
        try {
            const result = await validateCapacityQuery({ capacityJson: JSON.stringify(this.toPayload(q)) });
            this.updateQuery(rowId, () => ({
                valid: result.valid,
                invalidReason: result.invalidReason,
                validating: false
            }));
        } catch (error) {
            this.updateQuery(rowId, () => ({
                valid: false,
                invalidReason: reduceErrorMessage(error),
                validating: false
            }));
        }
    }

    // ------------------------------------------------------------------
    // Save
    // ------------------------------------------------------------------

    async handleSave(event) {
        const rowId = event.currentTarget.dataset.row;
        const q = this.queries.find((r) => r.clientId === rowId);
        if (!q) {
            return;
        }
        if (!q.label || !q.label.trim()) {
            this.toast('error', 'Give this count a label', 'A short label like "Open Accounts" shows up in skip reasons.');
            return;
        }
        this.updateQuery(rowId, () => ({ saving: true }));
        const expandedIds = new Set(
            this.queries.filter((r) => !r.collapsed && r.id).map((r) => r.id)
        );
        try {
            const savedId = await saveCapacityQuery({ capacityJson: JSON.stringify(this.toPayload(q)) });
            expandedIds.add(savedId);
            this.toast('success', 'Saved', q.label);
            this.dispatchEvent(new CustomEvent('refresh'));
            await this.loadQueries(expandedIds);
        } catch (error) {
            this.updateQuery(rowId, () => ({ saving: false }));
            this.toastError('Save failed', error);
        }
    }

    // ------------------------------------------------------------------
    // Derived getters
    // ------------------------------------------------------------------

    get hasQueries() {
        return this.queries.length > 0;
    }

    get isEmpty() {
        return !this.isLoading && this.queries.length === 0;
    }

    get leastLoadedWarning() {
        if (this.algorithm !== 'Least Loaded') {
            return null;
        }
        const hasLoadMetric = this.queries.some(
            (q) => q.active !== false && (q.role === ROLE_LOAD || q.role === ROLE_BOTH)
        );
        return hasLoadMetric
            ? null
            : 'Least Loaded has nothing to rank members on yet. Add at least one active count with a Load Metric role, otherwise this group falls back to Strict Rotation.';
    }

    get hasLeastLoadedWarning() {
        return !!this.leastLoadedWarning;
    }

    get rows() {
        return this.queries
            .slice()
            .sort((a, b) => (a.sortOrder || 0) - (b.sortOrder || 0))
            .map((q) => this.buildRowViewModel(q));
    }

    buildRowViewModel(q) {
        const objectLabel = (this.objectOptions.find((o) => o.value === q.objectName) || {}).label
            || q.objectName
            || 'No object chosen yet';
        const fields = this.fieldsFor(q.objectName);
        const ownerFieldOptions = fields
            .filter((f) => OWNER_FIELD_TYPES.has(f.fieldType))
            .map((f) => ({ label: f.label, value: f.apiName }));
        const fieldOptions = fields.map((f) => ({ label: f.label, value: f.apiName }));

        const showCap = q.role === ROLE_CAP || q.role === ROLE_BOTH;
        const showLoadWeight = q.role === ROLE_LOAD || q.role === ROLE_BOTH;

        const summaryParts = [objectLabel, q.role];
        if (showCap) {
            summaryParts.push(q.cap != null ? `cap ${q.cap}` : 'no cap set');
        }
        if (!q.active) {
            summaryParts.push('inactive');
        }

        return {
            key: q.clientId,
            clientId: q.clientId,
            id: q.id,
            label: q.label,
            objectName: q.objectName,
            ownerField: q.ownerField,
            role: q.role,
            cap: q.cap,
            loadWeight: q.loadWeight,
            filterLogic: q.filterLogic,
            active: q.active,
            sortOrder: q.sortOrder,
            description: q.description,
            objectLabel,
            fieldOptions,
            ownerFieldOptions,
            roleOptions: ROLE_OPTIONS.map((opt) => ({
                value: opt.value,
                label: opt.label,
                buttonClass:
                    'slds-button cq__rolebtn' + (q.role === opt.value ? ' slds-button_brand' : ' slds-button_neutral')
            })),
            showCap,
            showLoadWeight,
            summaryLine: summaryParts.join(' · '),
            expanded: !q.collapsed,
            toggleIcon: q.collapsed ? 'utility:chevronright' : 'utility:chevrondown',
            // aria-expanded needs the string form, and the title gives the button
            // an accessible name beyond the label text it already wraps.
            expandedAttr: q.collapsed ? 'false' : 'true',
            toggleTitle: q.collapsed ? 'Expand this count' : 'Collapse this count',
            cardClass: 'cq__card' + (q.collapsed ? '' : ' cq__card_open'),
            statusPill: this.pillViewModel(q),
            filters: q.filters.map((f) => this.buildFilterViewModel(q, f, fieldOptions)),
            hasFilters: q.filters.length > 0,
            noFilters: q.filters.length === 0,
            showInvalidReason: q.valid === false && !q.validating,
            showValidMsg: q.valid === true && !q.validating,
            invalidReason: q.invalidReason,
            deleteLabel: q.id ? 'Delete' : 'Discard',
            saveLabel: q.saving ? 'Saving…' : 'Save',
            saving: q.saving
        };
    }

    pillViewModel(q) {
        if (q.validating) {
            return { text: 'Checking…', cls: 'cq__pill cq__pill_checking' };
        }
        if (q.valid === true) {
            return { text: 'Will work', cls: 'cq__pill cq__pill_valid' };
        }
        if (q.valid === false) {
            return { text: 'Invalid', cls: 'cq__pill cq__pill_invalid' };
        }
        return { text: 'Not checked yet', cls: 'cq__pill cq__pill_unknown' };
    }

    buildFilterViewModel(q, f, fieldOptions) {
        const field = this.fieldsFor(q.objectName).find((x) => x.apiName === f.fieldName);
        const fieldType = field ? field.fieldType : null;
        const isTextual = TEXTUAL_TYPES.has(fieldType);
        const isMultipicklist = fieldType === 'MULTIPICKLIST';
        const isDateish = fieldType === 'DATE' || fieldType === 'DATETIME';
        const isGroupable = field ? !!field.groupable : false;

        const operatorOptions = OPERATOR_OPTIONS.filter((op) => {
            if (LIKE_OPERATORS.has(op.value) && !isTextual) {
                return false;
            }
            if (MULTIPICKLIST_OPERATORS.has(op.value) && !isMultipicklist) {
                return false;
            }
            return true;
        });

        const noValue = NO_VALUE_OPERATORS.has(f.operator);
        const isListOperator = LIST_OPERATORS.has(f.operator);

        const valueSourceOptions = [{ label: 'Literal', value: SRC_LITERAL }];
        if (isDateish) {
            valueSourceOptions.push({ label: 'Relative Date', value: SRC_RELATIVE_DATE });
        }
        if (isGroupable && f.operator === 'equals') {
            valueSourceOptions.push({ label: 'Routed Record Field', value: SRC_ROUTED_FIELD });
        }

        const picklistValues = field && field.picklistValues ? field.picklistValues : [];
        const hasPicklistValues = picklistValues.length > 0;
        const literalOptions = picklistValues.map((v) => ({ label: v, value: v }));

        const customMatch = CUSTOM_N_PATTERN.exec(f.value || '');
        const isCustomRelative = !!customMatch;

        return {
            clientId: f.clientId,
            rowId: q.clientId,
            fieldName: f.fieldName,
            operator: f.operator,
            valueSource: f.valueSource,
            value: f.value,
            routedRecordField: f.routedRecordField,
            fieldOptions,
            operatorOptions,
            valueSourceOptions,
            valuePlaceholder: isListOperator ? 'Comma-separated values' : 'Value',
            showValueSourcePicker: !noValue,
            showLiteralPicklist: !noValue && f.valueSource === SRC_LITERAL && hasPicklistValues,
            showLiteralText: !noValue && f.valueSource === SRC_LITERAL && !hasPicklistValues,
            showRelativeDate: !noValue && f.valueSource === SRC_RELATIVE_DATE,
            showRoutedField: !noValue && f.valueSource === SRC_ROUTED_FIELD,
            literalOptions,
            relativeOptions: RELATIVE_DATE_OPTIONS,
            relativeSelectValue: isCustomRelative ? CUSTOM_N_SENTINEL : f.value || '',
            isCustomRelative,
            customN: isCustomRelative ? customMatch[2] : '',
            customUnit: isCustomRelative ? customMatch[1] : 'DAYS'
        };
    }

    // ------------------------------------------------------------------
    // Toasts
    // ------------------------------------------------------------------

    toast(variant, title, message) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    toastError(title, error) {
        this.dispatchEvent(new ShowToastEvent({ title, message: reduceErrorMessage(error), variant: 'error' }));
    }
}
