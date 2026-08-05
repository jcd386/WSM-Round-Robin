import { LightningElement, api } from 'lwc';
import searchUsers from '@salesforce/apex/WSM_RR_AdminController.searchUsers';
import { reduceErrorMessage, debounce } from 'c/wsmRrUtils';

/**
 * Searchable User picker built on c-wsm-rr-combobox.
 * multi=false: single-select, fires 'select' {userId, name}.
 * multi=true: chip picker, fires 'chipschange' {value: [{userId, name}]} on every
 *   add/remove — the parent owns when to actually persist (e.g. an "Add" button
 *   that calls addMembers immediately, per the no-JS-only-datatable-rows rule).
 */
export default class WsmRrUserPicker extends LightningElement {
    @api groupId;
    @api multi = false;
    @api label;
    @api placeholder = 'Search users…';
    @api required = false;

    /** Saved selection (single mode): id + display label, shown before options load. */
    @api value;
    @api valueLabel;

    /** In-session pick; wins over the saved value until the parent refreshes. */
    _preset;

    options = [];
    chips = [];
    _debouncedSearch;

    connectedCallback() {
        this._debouncedSearch = debounce((term) => this.runSearch(term), 300);
        this.runSearch('');
    }

    get singleValue() {
        return this._preset ? this._preset.userId : this.value;
    }

    get singleLabel() {
        return this._preset ? this._preset.name : this.valueLabel;
    }

    get hasChips() {
        return this.chips.length > 0;
    }

    async runSearch(term) {
        try {
            const results = await searchUsers({ term: term || '', groupId: this.groupId || null });
            this.options = (results || [])
                .filter((u) => !this.multi || !this.chips.some((c) => c.userId === u.userId))
                .map((u) => ({ value: u.userId, label: u.name, sublabel: u.username }));
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
        if (this.multi) {
            if (!this.chips.some((c) => c.userId === value)) {
                this.chips = [...this.chips, { userId: value, name: option.label }];
                this.emitChipsChange();
            }
            const combobox = this.template.querySelector('c-wsm-rr-combobox');
            if (combobox) {
                combobox.clear();
            }
            this.runSearch('');
        } else {
            this._preset = { userId: value, name: option.label };
            this.dispatchEvent(
                new CustomEvent('select', { detail: { userId: value, name: option.label } })
            );
        }
    }

    handleRemoveChip(event) {
        const id = event.currentTarget.dataset.id;
        this.chips = this.chips.filter((c) => c.userId !== id);
        this.emitChipsChange();
        this.runSearch('');
    }

    emitChipsChange() {
        this.dispatchEvent(new CustomEvent('chipschange', { detail: { value: [...this.chips] } }));
    }

    /** Clears chips (multi) or the single selection — called by parent after a successful save. */
    @api
    reset() {
        this.chips = [];
        this._preset = null;
        const combobox = this.template.querySelector('c-wsm-rr-combobox');
        if (combobox) {
            combobox.clear();
        }
    }
}
