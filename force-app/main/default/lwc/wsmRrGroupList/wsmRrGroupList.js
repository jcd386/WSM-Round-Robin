import { LightningElement, api } from 'lwc';
import { algorithmAbbrev } from 'c/wsmRrUtils';

/** Left rail (~280px): group name, algorithm chip, active dot, member/30d counts. */
export default class WsmRrGroupList extends LightningElement {
    @api groups = [];
    @api selectedGroupId;
    @api filterTerm = '';

    get filtered() {
        const t = (this.filterTerm || '').toLowerCase().trim();
        if (!t) {
            return this.groups || [];
        }
        return (this.groups || []).filter((g) => (g.name || '').toLowerCase().includes(t));
    }

    get isEmpty() {
        return this.filtered.length === 0;
    }

    get rows() {
        return this.filtered.map((g) => ({
            ...g,
            algoAbbrev: algorithmAbbrev(g.algorithm),
            rowClass:
                'grl__item' + (g.groupId === this.selectedGroupId ? ' grl__item_selected' : ''),
            dotClass: 'grl__dot' + (g.active ? ' grl__dot_active' : ' grl__dot_inactive'),
            activeTitle: g.active ? 'Active' : 'Inactive'
        }));
    }

    handleClick(event) {
        const groupId = event.currentTarget.dataset.id;
        this.dispatchEvent(new CustomEvent('groupselect', { detail: { groupId } }));
    }
}
