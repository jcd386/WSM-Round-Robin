import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import saveGroup from '@salesforce/apex/WSM_RR_AdminController.saveGroup';
import addMembers from '@salesforce/apex/WSM_RR_AdminController.addMembers';
import updateMembers from '@salesforce/apex/WSM_RR_AdminController.updateMembers';
import setGroupActive from '@salesforce/apex/WSM_RR_AdminController.setGroupActive';
import { reduceErrorMessage, slugify } from 'c/wsmRrUtils';

const ALGORITHM_CAPTIONS = {
    'Strict Rotation': 'Everyone gets equal turns, in order.',
    Weighted: 'Higher weight = more assignments.',
    'Least Assigned': 'Whoever has the fewest this period goes next.'
};

const STEP_LABELS = ['Basics', 'Members', 'Review & activate'];

/**
 * 3-step "New Group" wizard. Renders as a centered modal (variant="modal", the
 * default — used from the "New Group" button) or as a full-width inline card
 * (variant="empty" — used as the Manager's zero-groups empty state).
 */
export default class WsmRrSetupWizard extends LightningElement {
    @api variant = 'modal';

    step = 1;
    isSaving = false;

    basics = {
        name: '',
        algorithm: 'Strict Rotation',
        capacityMode: 'None',
        period: 'Daily',
        defaultMemberCap: null,
        fallbackUserId: null,
        fallbackUserName: null,
        fallbackQueueId: null,
        fallbackQueueName: null
    };
    pendingMembers = [];
    activate = true;

    algorithms = ['Strict Rotation', 'Weighted', 'Least Assigned'];
    periods = ['Daily', 'Weekly', 'Monthly'];

    get isModal() {
        return this.variant !== 'empty';
    }

    get isEmptyVariant() {
        return this.variant === 'empty';
    }

    get containerClass() {
        return this.isModal
            ? 'slds-modal slds-fade-in-open slds-modal_medium wiz__modal'
            : 'wiz__card';
    }

    get title() {
        return this.isEmptyVariant ? 'Create your first Round Robin group' : 'New Round Robin group';
    }

    get titleClass() {
        return this.isModal ? 'slds-modal__title' : 'wiz__cardtitle';
    }

    get stepIndicatorClass() {
        return this.isModal ? 'wiz__steplabel_modal' : 'wiz__steplabel';
    }

    get closeIconVariant() {
        return 'inverse';
    }

    get stepIndicator() {
        return `Step ${this.step} of 3 — ${STEP_LABELS[this.step - 1]}`;
    }

    get isStep1() {
        return this.step === 1;
    }

    get isStep2() {
        return this.step === 2;
    }

    get isStep3() {
        return this.step === 3;
    }

    get isFirstStep() {
        return this.step === 1;
    }

    get isLastStep() {
        return this.step === 3;
    }

    get isNotLastStep() {
        return this.step !== 3;
    }

    get algorithmOptions() {
        return this.algorithms.map((a) => ({
            value: a,
            label: a,
            buttonClass: this.buttonClass(this.basics.algorithm === a)
        }));
    }

    get periodOptions() {
        return this.periods.map((p) => ({
            value: p,
            label: p,
            buttonClass: this.buttonClass((this.basics.period || 'Daily') === p)
        }));
    }

    buttonClass(selected) {
        return 'slds-button wiz__btn' + (selected ? ' slds-button_brand' : ' slds-button_neutral');
    }

    get algorithmCaption() {
        return ALGORITHM_CAPTIONS[this.basics.algorithm] || '';
    }

    get isWeighted() {
        return this.basics.algorithm === 'Weighted';
    }

    get isCapacityEnabled() {
        return this.basics.capacityMode === 'Period Cap';
    }

    get hasPendingMembers() {
        return this.pendingMembers.length > 0;
    }

    get hasNoPendingMembers() {
        return !this.hasPendingMembers;
    }

    get capacitySummary() {
        if (!this.isCapacityEnabled) {
            return 'No cap';
        }
        const cap = this.basics.defaultMemberCap == null ? 'uncapped' : this.basics.defaultMemberCap;
        return `${this.basics.period} — default cap ${cap}`;
    }

    get fallbackSummary() {
        if (this.basics.fallbackUserName) {
            return this.basics.fallbackUserName;
        }
        if (this.basics.fallbackQueueName) {
            return this.basics.fallbackQueueName + ' (Queue)';
        }
        return 'None set';
    }

    get fallbackValue() {
        return this.basics.fallbackUserId || this.basics.fallbackQueueId;
    }

    get fallbackLabel() {
        if (this.basics.fallbackUserId) {
            return this.basics.fallbackUserName;
        }
        if (this.basics.fallbackQueueId) {
            return this.basics.fallbackQueueName + ' (Queue)';
        }
        return null;
    }

    get memberCountSummary() {
        return `${this.pendingMembers.length} member${this.pendingMembers.length === 1 ? '' : 's'}`;
    }

    get finishLabel() {
        return this.isSaving ? 'Creating…' : 'Create group';
    }

    get isNextDisabled() {
        if (this.step === 1) {
            return !this.basics.name || !this.basics.name.trim();
        }
        return false;
    }

    get isFinishDisabled() {
        return this.isSaving;
    }

    handleNameChange(event) {
        this.basics = { ...this.basics, name: event.target.value };
    }

    handleAlgorithmClick(event) {
        this.basics = { ...this.basics, algorithm: event.currentTarget.dataset.value };
    }

    handlePeriodClick(event) {
        this.basics = { ...this.basics, period: event.currentTarget.dataset.value };
    }

    handleCapacityToggle(event) {
        this.basics = { ...this.basics, capacityMode: event.target.checked ? 'Period Cap' : 'None' };
    }

    handleCapChange(event) {
        const raw = event.target.value;
        this.basics = { ...this.basics, defaultMemberCap: raw === '' ? null : Number(raw) };
    }

    handleFallbackSelect(event) {
        const { targetId, name, targetType } = event.detail;
        const isQueue = targetType === 'Queue';
        this.basics = {
            ...this.basics,
            fallbackUserId: isQueue ? null : targetId,
            fallbackUserName: isQueue ? null : name,
            fallbackQueueId: isQueue ? targetId : null,
            fallbackQueueName: isQueue ? name : null
        };
    }

    handleFallbackClear() {
        this.basics = {
            ...this.basics,
            fallbackUserId: null,
            fallbackUserName: null,
            fallbackQueueId: null,
            fallbackQueueName: null
        };
    }

    handleChipsChange(event) {
        const chips = event.detail.value;
        const existingIds = new Set(this.pendingMembers.map((m) => m.userId));
        const additions = chips
            .filter((c) => !existingIds.has(c.userId))
            .map((c) => ({ userId: c.userId, name: c.name, weight: 1 }));
        this.pendingMembers = [...this.pendingMembers, ...additions];
    }

    handleWeightChange(event) {
        const id = event.currentTarget.dataset.id;
        const val = event.target.value === '' ? 1 : Number(event.target.value);
        this.pendingMembers = this.pendingMembers.map((m) => (m.userId === id ? { ...m, weight: val } : m));
    }

    handleRemoveMember(event) {
        const id = event.currentTarget.dataset.id;
        this.pendingMembers = this.pendingMembers.filter((m) => m.userId !== id);
    }

    handleActivateToggle(event) {
        this.activate = event.target.checked;
    }

    handleBack() {
        if (this.step > 1) {
            this.step -= 1;
        }
    }

    handleNext() {
        if (this.isNextDisabled) {
            return;
        }
        if (this.step < 3) {
            this.step += 1;
        }
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    async handleFinish() {
        this.isSaving = true;
        try {
            const developerName = slugify(this.basics.name);
            const groupJson = JSON.stringify({
                name: this.basics.name,
                developerName,
                algorithm: this.basics.algorithm,
                capacityMode: this.basics.capacityMode,
                period: this.basics.period,
                defaultMemberCap: this.basics.defaultMemberCap,
                fallbackUserId: this.basics.fallbackUserId,
                fallbackQueueId: this.basics.fallbackQueueId,
                calibration: 'Median',
                description: ''
            });
            const groupId = await saveGroup({ groupJson });

            if (this.pendingMembers.length) {
                const userIds = this.pendingMembers.map((m) => m.userId);
                const memberIds = await addMembers({ groupId, userIds });
                if (this.isWeighted && memberIds && memberIds.length === this.pendingMembers.length) {
                    const patches = memberIds
                        .map((memberId, idx) => ({ memberId, weight: this.pendingMembers[idx].weight }))
                        .filter((p) => p.weight && p.weight !== 1);
                    if (patches.length) {
                        await updateMembers({ membersJson: JSON.stringify(patches) });
                    }
                }
            }

            if (!this.activate) {
                await setGroupActive({ groupId, active: false });
            }

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Group created',
                    message: 'Next: open the Wiring tab to connect it to a Flow.',
                    variant: 'success'
                })
            );
            this.dispatchEvent(new CustomEvent('created', { detail: { groupId } }));
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Could not create group', message: reduceErrorMessage(error), variant: 'error' })
            );
        } finally {
            this.isSaving = false;
        }
    }
}
