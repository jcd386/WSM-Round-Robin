import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getGroupDetail from '@salesforce/apex/WSM_RR_AdminController.getGroupDetail';
import saveGroup from '@salesforce/apex/WSM_RR_AdminController.saveGroup';
import setGroupActive from '@salesforce/apex/WSM_RR_AdminController.setGroupActive';
import deleteGroup from '@salesforce/apex/WSM_RR_AdminController.deleteGroup';
import resetCounters from '@salesforce/apex/WSM_RR_AdminController.resetCounters';
import { reduceErrorMessage, isWithinDays } from 'c/wsmRrUtils';

/**
 * Group workspace: header (rename, active toggle, test assignment, overflow menu,
 * lifecycle chips) + Members/Settings/Activity/Wiring tabset. Works both as the
 * Manager's right-hand pane (group-id set imperatively) and standalone on the
 * Group record page (record-id fallback).
 */
export default class WsmRrGroupWorkspace extends LightningElement {
    _groupId;
    @api
    get groupId() {
        return this._groupId;
    }
    set groupId(val) {
        this._groupId = val;
        if (val) {
            this.loadDetail(val);
        }
    }

    _recordId;
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(val) {
        this._recordId = val;
        if (!this._groupId && val) {
            this.loadDetail(val);
        }
    }

    _initialTab;
    @api
    get initialTab() {
        return this._initialTab;
    }
    set initialTab(val) {
        this._initialTab = val;
        if (val) {
            this.activeTabValue = val;
            this.showCreatedBanner = val === 'wiring';
        }
    }

    isLoading = false;
    grp;
    members = [];
    recentLogs = [];
    periodLabel = '';
    hasAnyLog = false;

    activeTabValue = 'members';
    showCreatedBanner = false;

    editingName = false;
    nameDraft = '';

    showOverflow = false;
    showDeactivateConfirm = false;
    showResetConfirm = false;
    showDeleteConfirm = false;
    showSimulator = false;

    get effectiveGroupId() {
        return this._groupId || this._recordId;
    }

    get hasGroup() {
        return !this.isLoading && !!this.grp;
    }

    get notEditingName() {
        return !this.editingName;
    }

    get activeLabel() {
        return this.grp && this.grp.active ? 'Active' : 'Inactive';
    }

    get membersCheck() {
        return this.members && this.members.length ? '✓' : '-';
    }

    get activeCheck() {
        return this.grp && this.grp.active ? '✓' : '-';
    }

    get wiredCheck() {
        return this.hasAnyLog ? '✓' : '-';
    }

    get membersChipClass() {
        return 'gw__lcchip' + (this.members && this.members.length ? ' gw__lcchip_done' : '');
    }

    get activeChipClass() {
        return 'gw__lcchip' + (this.grp && this.grp.active ? ' gw__lcchip_done' : '');
    }

    get wiredChipClass() {
        return 'gw__lcchip' + (this.hasAnyLog ? ' gw__lcchip_done' : '');
    }

    async loadDetail(id) {
        this.isLoading = true;
        try {
            const detail = await getGroupDetail({ groupId: id });
            this.grp = detail.grp;
            this.members = detail.members || [];
            this.recentLogs = detail.recentLogs || [];
            this.periodLabel = detail.periodLabel;
            this.hasAnyLog = detail.hasAnyLog;
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not load group', message: reduceErrorMessage(error), variant: 'error' })
            );
        } finally {
            this.isLoading = false;
        }
    }

    reload() {
        if (this.effectiveGroupId) {
            this.loadDetail(this.effectiveGroupId);
        }
    }

    handleChildRefresh() {
        this.reload();
        this.dispatchEvent(new CustomEvent('groupchanged'));
    }

    dismissBanner() {
        this.showCreatedBanner = false;
    }

    startNameEdit() {
        this.nameDraft = this.grp.name;
        this.editingName = true;
    }

    handleNameInput(event) {
        this.nameDraft = event.target.value;
    }

    handleNameKeydown(event) {
        if (event.key === 'Enter') {
            this.template.querySelector('.gw__nameinput').blur();
        } else if (event.key === 'Escape') {
            this.editingName = false;
        }
    }

    async saveNameEdit() {
        this.editingName = false;
        const trimmed = (this.nameDraft || '').trim();
        if (!trimmed || trimmed === this.grp.name) {
            return;
        }
        try {
            await saveGroup({ groupJson: JSON.stringify({ ...this.grp, name: trimmed }) });
            this.grp = { ...this.grp, name: trimmed };
            this.dispatchEvent(new CustomEvent('groupchanged'));
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Rename failed', message: reduceErrorMessage(error), variant: 'error' })
            );
        }
    }

    handleCopyDevName() {
        if (navigator.clipboard) {
            navigator.clipboard.writeText(this.grp.developerName || '');
        }
        this.dispatchEvent(new ShowToastEvent({ title: 'Copied', variant: 'success' }));
    }

    get recentAssignmentCount7d() {
        return (this.recentLogs || []).filter(
            (l) => l.status === 'ASSIGNED' && isWithinDays(l.timestampValue, 7)
        ).length;
    }

    handleActiveToggle(event) {
        const nextActive = event.target.checked;
        if (!nextActive && this.recentAssignmentCount7d > 0) {
            // revert the visual toggle until confirmed
            event.target.checked = this.grp.active;
            this.showDeactivateConfirm = true;
            return;
        }
        this.setActive(nextActive);
    }

    cancelDeactivate() {
        this.showDeactivateConfirm = false;
    }

    confirmDeactivate() {
        this.showDeactivateConfirm = false;
        this.setActive(false);
    }

    async setActive(active) {
        try {
            await setGroupActive({ groupId: this.effectiveGroupId, active });
            this.grp = { ...this.grp, active };
            this.dispatchEvent(new CustomEvent('groupchanged'));
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not update', message: reduceErrorMessage(error), variant: 'error' })
            );
        }
    }

    toggleOverflow() {
        this.showOverflow = !this.showOverflow;
    }

    openResetConfirm() {
        this.showOverflow = false;
        this.showResetConfirm = true;
    }

    cancelReset() {
        this.showResetConfirm = false;
    }

    async confirmReset() {
        this.showResetConfirm = false;
        try {
            await resetCounters({ groupId: this.effectiveGroupId });
            this.dispatchEvent(new ShowToastEvent({ title: 'Counters reset', variant: 'success' }));
            this.reload();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Reset failed', message: reduceErrorMessage(error), variant: 'error' })
            );
        }
    }

    openDeleteConfirm() {
        this.showOverflow = false;
        this.showDeleteConfirm = true;
    }

    cancelDelete() {
        this.showDeleteConfirm = false;
    }

    async confirmDelete() {
        this.showDeleteConfirm = false;
        try {
            await deleteGroup({ groupId: this.effectiveGroupId });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Group deleted', message: this.grp.name, variant: 'success' })
            );
            this.dispatchEvent(new CustomEvent('groupdeleted', { detail: { groupId: this.effectiveGroupId } }));
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Delete failed', message: reduceErrorMessage(error), variant: 'error' })
            );
        }
    }

    openSimulator() {
        this.showSimulator = true;
    }

    closeSimulator() {
        this.showSimulator = false;
    }
}
