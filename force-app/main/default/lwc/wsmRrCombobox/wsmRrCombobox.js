import { LightningElement, api, track } from 'lwc';

/**
 * Shared searchable combobox primitive (see docs/lwc-best-practices.md
 * "Selection Inputs: Searchable Combobox by Default"). Full list on focus,
 * case-insensitive includes() filter, onmousedown select (fires before
 * blur closes the list).
 */
export default class WsmRrCombobox extends LightningElement {
    @api label;
    @api placeholder = 'Search…';
    @api disabled = false;
    @api required = false;

    _options = [];
    @api
    get options() {
        return this._options;
    }
    set options(value) {
        this._options = Array.isArray(value) ? value : [];
        this.syncLabelFromValue();
    }

    _value = null;
    @api
    get value() {
        return this._value;
    }
    set value(val) {
        this._value = val;
        this.syncLabelFromValue();
    }

    @track searchTerm = '';
    isOpen = false;

    /**
     * Display label for a preselected value whose option may not be loaded yet
     * (options load lazily on focus). Lets parents show a saved selection.
     */
    _valueLabel;
    @api
    get valueLabel() {
        return this._valueLabel;
    }
    set valueLabel(v) {
        this._valueLabel = v;
        if (v && !this.isOpen) {
            this.searchTerm = v;
        }
    }

    syncLabelFromValue() {
        if (this._value == null) {
            return;
        }
        const match = this._options.find((o) => o.value === this._value);
        if (match) {
            this.searchTerm = match.label;
        }
    }

    get comboboxClass() {
        return (
            'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click' +
            (this.isOpen ? ' slds-is-open' : '')
        );
    }

    get filteredOptions() {
        const t = (this.searchTerm || '').toLowerCase();
        if (!t) {
            return this._options;
        }
        return this._options.filter(
            (o) =>
                (o.label || '').toLowerCase().includes(t) ||
                (o.sublabel || '').toLowerCase().includes(t)
        );
    }

    get noMatches() {
        return this.isOpen && this.filteredOptions.length === 0;
    }

    handleFocus() {
        this.isOpen = true;
        this.dispatchEvent(new CustomEvent('focusopen'));
    }

    handleBlur() {
        this.isOpen = false;
    }

    handleSearch(event) {
        this.searchTerm = event.target.value;
        this.isOpen = true;
        if (this._value !== null) {
            this._value = null;
        }
        this.dispatchEvent(new CustomEvent('search', { detail: { term: this.searchTerm } }));
    }

    handleSelect(event) {
        const selectedValue = event.currentTarget.dataset.value;
        const selected = this._options.find((o) => String(o.value) === String(selectedValue));
        if (!selected) {
            return;
        }
        this.searchTerm = selected.label;
        this._value = selected.value;
        this.isOpen = false;
        this.dispatchEvent(
            new CustomEvent('change', { detail: { value: selected.value, option: selected } })
        );
    }

    /** Clears the input and selection without emitting a change event. */
    @api
    clear() {
        this.searchTerm = '';
        this._value = null;
    }
}
