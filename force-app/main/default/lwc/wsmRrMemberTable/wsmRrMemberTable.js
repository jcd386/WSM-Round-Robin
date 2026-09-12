import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import addMembers from '@salesforce/apex/WSM_RR_AdminController.addMembers';
import updateMembers from '@salesforce/apex/WSM_RR_AdminController.updateMembers';
import removeMember from '@salesforce/apex/WSM_RR_AdminController.removeMember';
import reorderMembers from '@salesforce/apex/WSM_RR_AdminController.reorderMembers';
import { reduceErrorMessage } from 'c/wsmRrUtils';

/**
 * Members tab: inline multi-add row + dense hand-rolled table.
 * Every mutation (toggle, weight, cap, OOO, order, remove) saves immediately,
 * this table never holds unsaved JS-pushed rows (see lwc-best-practices.md).
 */
export default class WsmRrMemberTable extends LightningElement {
    @api groupId;
    @api algorithm;
    @api capacityMode;
    @api period;
    @api members = [];

    pendingUserIds = [];
    openOooId = null;
    oooDraftStart = null;
    oooDraftReturn = null;
    showRemoveConfirm = false;
    removeTargetId = null;
    removeTargetName = '';

    get showWeight() {
        return this.algorithm === 'Weighted';
    }

    get showCapacity() {
        return this.capacityMode === 'Period Cap';
    }

    get showOrder() {
        return this.algorithm === 'Strict Rotation';
    }

    get sortedMembers() {
        return [...(this.members || [])].sort((a, b) => {
            const tierA = a.tier == null ? 1 : a.tier;
            const tierB = b.tier == null ? 1 : b.tier;
            if (tierA !== tierB) {
                return tierA - tierB;
            }
            return (a.sortOrder || 0) - (b.sortOrder || 0);
        });
    }

    get capHeader() {
        const per = { Daily: 'day', Weekly: 'week', Monthly: 'month' }[this.period];
        return per ? `Cap / ${per}` : 'Cap';
    }

    get usedHeader() {
        return (
            { Daily: 'Assigned today', Weekly: 'Assigned this week', Monthly: 'Assigned this month' }[
                this.period
            ] || 'Assigned'
        );
    }

    get rows() {
        const sorted = this.sortedMembers;
        let prevTier = null;
        return sorted.map((m, idx) => {
            const hasCap = m.effectiveCap !== null && m.effectiveCap !== undefined;
            const capped = this.capacityMode === 'Period Cap' && hasCap;
            const tier = m.tier == null ? 1 : m.tier;
            const showTierDivider = tier !== prevTier;
            prevTier = tier;
            return {
                ...m,
                tier,
                showTierDivider,
                tierDividerKey: `tier-${tier}`,
                tierDividerLabel: tier <= 1 ? 'Tier 1: primary pool' : `Tier ${tier}: bench`,
                rowClass: 'mt__row' + (m.active ? '' : ' mt__row_inactive') + (tier > 1 ? ' mt__row_bench' : ''),
                capPlaceholder: m.capOverride === null || m.capOverride === undefined ? (hasCap ? String(m.effectiveCap) : 'none') : '',
                usedLabel: capped ? `${m.periodCount} of ${m.effectiveCap}` : String(m.periodCount || 0),
                oooLabel: this.formatOoo(m),
                oooTitle: this.formatOooTitle(m),
                oooBtnClass: 'slds-button mt__oobtn' + (m.oooStart || m.oooReturn ? ' mt__oobtn_set' : ''),
                oooOpen: this.openOooId === m.memberId,
                isFirst: idx === 0,
                isLast: idx === sorted.length - 1
            };
        });
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get isEmpty() {
        return !this.hasRows;
    }

    get addCountLabel() {
        return this.pendingUserIds.length ? `(${this.pendingUserIds.length})` : '';
    }

    get isAddDisabled() {
        return this.pendingUserIds.length === 0;
    }

    formatOoo(m) {
        if (!m.oooStart && !m.oooReturn) {
            return 'Set OOO';
        }
        if (m.oooStart && m.oooReturn) {
            return `${this.shortDate(m.oooStart)} to ${this.shortDate(m.oooReturn)}`;
        }
        return m.oooStart ? `From ${this.shortDate(m.oooStart)}` : `Until ${this.shortDate(m.oooReturn)}`;
    }

    formatOooTitle(m) {
        if (!m.oooStart && !m.oooReturn) {
            return 'Set an out-of-office range. The member is skipped while away';
        }
        const ret = m.oooReturn ? `eligible again ${this.shortDate(m.oooReturn)}` : 'no return date set';
        return `Out of office until ${ret}. Click to edit.`;
    }

    // Parse 'YYYY-MM-DD' as local date parts; new Date(str) would shift a day in negative-UTC timezones.
    shortDate(iso) {
        const [y, mo, d] = String(iso).split('-').map(Number);
        if (!y || !mo || !d) {
            return iso;
        }
        return new Date(y, mo - 1, d).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    }

    handleChipsChange(event) {
        this.pendingUserIds = event.detail.value.map((c) => c.userId);
    }

    async handleAdd() {
        if (!this.pendingUserIds.length) {
            return;
        }
        try {
            await addMembers({ groupId: this.groupId, userIds: this.pendingUserIds });
            this.pendingUserIds = [];
            const picker = this.template.querySelector('c-wsm-rr-user-picker');
            if (picker) {
                picker.reset();
            }
            this.toast('success', 'Members added');
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (error) {
            this.toast('error', 'Could not add members', error);
        }
    }

    async persist(memberId, patch) {
        try {
            await updateMembers({ membersJson: JSON.stringify([{ memberId, ...patch }]) });
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (error) {
            this.toast('error', 'Update failed', error);
        }
    }

    handleActiveToggle(event) {
        this.persist(event.currentTarget.dataset.id, { active: event.target.checked });
    }

    handleWeightChange(event) {
        const val = event.target.value === '' ? null : Number(event.target.value);
        this.persist(event.currentTarget.dataset.id, { weight: val });
    }

    handleCapChange(event) {
        const val = event.target.value === '' ? null : Number(event.target.value);
        this.persist(event.currentTarget.dataset.id, { capOverride: val });
    }

    handleTierChange(event) {
        const raw = event.target.value;
        const val = raw === '' ? 1 : Number(raw);
        this.persist(event.currentTarget.dataset.id, { tier: val });
    }

    toggleOooPopover(event) {
        const id = event.currentTarget.dataset.id;
        if (this.openOooId === id) {
            this.openOooId = null;
            return;
        }
        const row = this.rows.find((r) => r.memberId === id);
        this.oooDraftStart = row ? row.oooStart : null;
        this.oooDraftReturn = row ? row.oooReturn : null;
        this.openOooId = id;
    }

    handleOooStartChange(event) {
        this.oooDraftStart = event.target.value;
    }

    handleOooReturnChange(event) {
        this.oooDraftReturn = event.target.value;
    }

    saveOoo(event) {
        const id = event.currentTarget.dataset.id;
        this.persist(id, { oooStart: this.oooDraftStart || null, oooReturn: this.oooDraftReturn || null });
        this.openOooId = null;
    }

    clearOoo(event) {
        const id = event.currentTarget.dataset.id;
        this.persist(id, { oooStart: null, oooReturn: null });
        this.openOooId = null;
    }

    async moveUp(event) {
        this.reorder(event.currentTarget.dataset.id, -1);
    }

    async moveDown(event) {
        this.reorder(event.currentTarget.dataset.id, 1);
    }

    async reorder(memberId, delta) {
        const ids = this.sortedMembers.map((m) => m.memberId);
        const idx = ids.indexOf(memberId);
        const swapIdx = idx + delta;
        if (swapIdx < 0 || swapIdx >= ids.length) {
            return;
        }
        [ids[idx], ids[swapIdx]] = [ids[swapIdx], ids[idx]];
        try {
            await reorderMembers({ groupId: this.groupId, orderedMemberIds: ids });
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (error) {
            this.toast('error', 'Reorder failed', error);
        }
    }

    confirmRemove(event) {
        const id = event.currentTarget.dataset.id;
        const row = this.rows.find((r) => r.memberId === id);
        this.removeTargetId = id;
        this.removeTargetName = row ? row.userName : 'this member';
        this.showRemoveConfirm = true;
    }

    cancelRemove() {
        this.showRemoveConfirm = false;
        this.removeTargetId = null;
    }

    async doRemove() {
        try {
            await removeMember({ memberId: this.removeTargetId });
            this.toast('success', 'Member removed');
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (error) {
            this.toast('error', 'Remove failed', error);
        } finally {
            this.showRemoveConfirm = false;
            this.removeTargetId = null;
        }
    }

    toast(variant, title, error) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message: error ? reduceErrorMessage(error) : undefined,
                variant
            })
        );
    }
}
