import { LightningElement, api } from 'lwc';
import searchFallbackTargets from '@salesforce/apex/WSM_RR_AdminController.searchFallbackTargets';
import { reduceErrorMessage, debounce } from 'c/wsmRrUtils';

/**
 * Searchable picker over users AND queues for the group fallback setting.
 * Fires 'select' {targetId, name, targetType: 'User'|'Queue'} and
 * 'clear' when the selection is removed.
 */
export default class WsmRrFallbackPicker extends LightningElement {
    @api label;
    @api placeholder = 'Search users and queues…';

    /** Saved selection shown before options load. */
    @api value;
    @api valueLabel;

    _preset;
    options = [];
    _debouncedSearch;

    connectedCallback() {
        this._debouncedSearch = debounce((term) => this.runSearch(term), 300);
        this.runSearch('');
    }

    get singleValue() {
        return this._preset ? this._preset.targetId : this.value;
    }

    get singleLabel() {
        return this._preset ? this._preset.name : this.valueLabel;
    }

    async runSearch(term) {
        try {
            const results = await searchFallbackTargets({ term: term || '' });
            this.options = (results || []).map((t) => ({
                value: t.targetId,
                label: t.name,
                sublabel: t.targetType
            }));
        } catch (error) {
            this.dispatchEvent(
                new CustomEvent('pickererror', { detail: { message: reduceErrorMessage(error) } })
            );
        }
    }

    handleFocusOpen() {
        this.runSearch('');
    }

    handleSearch(event) {
        this._debouncedSearch(event.detail.term);
    }

    handleChange(event) {
        const { value, option } = event.detail;
        this._preset = { targetId: value, name: option.label, targetType: option.sublabel };
        this.dispatchEvent(
            new CustomEvent('select', {
                detail: { targetId: value, name: option.label, targetType: option.sublabel }
            })
        );
    }

    handleClear() {
        this._preset = null;
        const combobox = this.template.querySelector('c-wsm-rr-combobox');
        if (combobox) {
            combobox.clear();
        }
        this.dispatchEvent(new CustomEvent('clear'));
    }

    get hasSelection() {
        return !!(this.singleValue && this.singleLabel);
    }
}
