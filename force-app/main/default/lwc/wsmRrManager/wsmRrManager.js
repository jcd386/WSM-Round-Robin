import { LightningElement } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getGroups from '@salesforce/apex/WSM_RR_AdminController.getGroups';
import { reduceErrorMessage } from 'c/wsmRrUtils';

/**
 * App page shell: top bar (title, group search, New Group) + CSS-grid rail/workspace.
 * States: loading spinner / zero-groups full-width wizard / rail+workspace.
 */
export default class WsmRrManager extends LightningElement {
    isLoading = true;
    groups = [];
    selectedGroupId;
    filterTerm = '';
    showWizardModal = false;
    pendingInitialTab;

    connectedCallback() {
        this.loadGroups();
    }

    get showEmptyState() {
        return !this.isLoading && this.groups.length === 0;
    }

    get showWorkspace() {
        return !this.isLoading && this.groups.length > 0;
    }

    get noSelection() {
        return !this.selectedGroupId;
    }

    async loadGroups(preserveSelection = true) {
        this.isLoading = true;
        try {
            this.groups = (await getGroups()) || [];
            if (!preserveSelection || !this.groups.some((g) => g.groupId === this.selectedGroupId)) {
                this.selectedGroupId = this.groups.length ? this.groups[0].groupId : undefined;
            }
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not load groups', message: reduceErrorMessage(error), variant: 'error' })
            );
        } finally {
            this.isLoading = false;
        }
    }

    handleSearchChange(event) {
        this.filterTerm = event.target.value;
    }

    handleNewGroupClick() {
        this.showWizardModal = true;
    }

    handleWizardCancel() {
        this.showWizardModal = false;
    }

    async handleWizardCreated(event) {
        this.showWizardModal = false;
        this.pendingInitialTab = 'wiring';
        await this.loadGroups(false);
        this.selectedGroupId = event.detail.groupId;
    }

    handleGroupSelect(event) {
        this.selectedGroupId = event.detail.groupId;
    }

    handleGroupChanged() {
        this.loadGroups(true);
    }

    handleGroupDeleted() {
        this.selectedGroupId = undefined;
        this.loadGroups(false);
    }
}
