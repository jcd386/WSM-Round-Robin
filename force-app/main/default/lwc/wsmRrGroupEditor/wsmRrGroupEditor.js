import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import saveGroup from '@salesforce/apex/WSM_RR_AdminController.saveGroup';
import { reduceErrorMessage, slugify } from 'c/wsmRrUtils';

const ALGORITHM_CAPTIONS = {
    'Strict Rotation': 'Everyone gets equal turns, in order.',
    Weighted: 'Higher weight = more assignments.',
    'Least Assigned': 'Whoever has the fewest this period goes next.'
};

const CALIBRATION_CAPTIONS = {
    Median: 'New or returning members join mid-period at the pool median, not zero, avoids a flood.',
    None: 'New members start at zero and may receive several in a row to catch up.'
};

/** Settings tab: algorithm, capacity, fallback, developer-name slug, description. */
export default class WsmRrGroupEditor extends LightningElement {
    working = {};
    _original = {};

    @api
    get grp() {
        return this.working;
    }
    set grp(value) {
        const snapshot = { ...(value || {}) };
        this._original = snapshot;
        this.working = { ...snapshot };
        this._slugTouched = false;
    }

    _slugTouched = false;
    isSaving = false;

    algorithms = ['Strict Rotation', 'Weighted', 'Least Assigned'];
    calibrations = ['Median', 'None'];
    periods = ['Daily', 'Weekly', 'Monthly'];

    get algorithmOptions() {
        return this.algorithms.map((a) => ({
            value: a,
            label: a,
            buttonClass: this.buttonClass(this.working.algorithm === a)
        }));
    }

    get calibrationOptions() {
        return this.calibrations.map((c) => ({
            value: c,
            label: c,
            buttonClass: this.buttonClass((this.working.calibration || 'Median') === c)
        }));
    }

    get periodOptions() {
        return this.periods.map((p) => ({
            value: p,
            label: p,
            buttonClass: this.buttonClass((this.working.period || 'Daily') === p)
        }));
    }

    buttonClass(selected) {
        return (
            'slds-button ge__btn' +
            (selected ? ' slds-button_brand' : ' slds-button_neutral')
        );
    }

    get algorithmCaption() {
        return ALGORITHM_CAPTIONS[this.working.algorithm] || '';
    }

    get isLeastAssigned() {
        return this.working.algorithm === 'Least Assigned';
    }

    get calibrationCaption() {
        return CALIBRATION_CAPTIONS[this.working.calibration || 'Median'];
    }

    get isCapacityEnabled() {
        return this.working.capacityMode === 'Period Cap';
    }

    get defaultMemberCap() {
        return this.working.defaultMemberCap;
    }

    get fallbackValue() {
        return this.working.fallbackUserId || this.working.fallbackQueueId;
    }

    get fallbackLabel() {
        if (this.working.fallbackUserId) {
            return this.working.fallbackUserName;
        }
        if (this.working.fallbackQueueId) {
            return this.working.fallbackQueueName
                ? `${this.working.fallbackQueueName} (Queue)`
                : this.working.fallbackQueueId;
        }
        return null;
    }

    get developerName() {
        return this.working.developerName || (this._slugTouched ? '' : slugify(this.working.name));
    }

    get isSlugEditable() {
        return !this._original.id;
    }

    get isSlugReadOnly() {
        return !!this._original.id;
    }

    get description() {
        return this.working.description;
    }

    get isDirty() {
        return JSON.stringify(this.working) !== JSON.stringify(this._original);
    }

    get isSaveDisabled() {
        return !this.isDirty || this.isSaving;
    }

    handleAlgorithmClick(event) {
        this.working = { ...this.working, algorithm: event.currentTarget.dataset.value };
    }

    handleCalibrationClick(event) {
        this.working = { ...this.working, calibration: event.currentTarget.dataset.value };
    }

    handlePeriodClick(event) {
        this.working = { ...this.working, period: event.currentTarget.dataset.value };
    }

    handleCapacityToggle(event) {
        this.working = {
            ...this.working,
            capacityMode: event.target.checked ? 'Period Cap' : 'None',
            period: this.working.period || 'Daily'
        };
    }

    handleCapChange(event) {
        const raw = event.target.value;
        this.working = { ...this.working, defaultMemberCap: raw === '' ? null : Number(raw) };
    }

    handleFallbackSelect(event) {
        const { targetId, name, targetType } = event.detail;
        const isQueue = targetType === 'Queue';
        this.working = {
            ...this.working,
            fallbackUserId: isQueue ? null : targetId,
            fallbackUserName: isQueue ? null : name,
            fallbackQueueId: isQueue ? targetId : null,
            fallbackQueueName: isQueue ? name : null
        };
    }

    handleFallbackClear() {
        this.working = {
            ...this.working,
            fallbackUserId: null,
            fallbackUserName: null,
            fallbackQueueId: null,
            fallbackQueueName: null
        };
    }

    handleDevNameChange(event) {
        this._slugTouched = true;
        this.working = { ...this.working, developerName: slugify(event.target.value) };
    }

    handleCopyDevName() {
        if (navigator.clipboard) {
            navigator.clipboard.writeText(this.working.developerName || '');
        }
        this.dispatchEvent(
            new ShowToastEvent({ title: 'Copied', message: 'Developer name copied.', variant: 'success' })
        );
    }

    handleDescriptionChange(event) {
        this.working = { ...this.working, description: event.target.value };
    }

    async handleSave() {
        this.isSaving = true;
        try {
            const payload = {
                ...this.working,
                developerName: this.working.developerName || slugify(this.working.name)
            };
            const groupId = await saveGroup({ groupJson: JSON.stringify(payload) });
            this._original = { ...this.working, id: groupId, developerName: payload.developerName };
            this.working = { ...this._original };
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Saved', message: 'Group settings updated.', variant: 'success' })
            );
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Save failed', message: reduceErrorMessage(error), variant: 'error' })
            );
        } finally {
            this.isSaving = false;
        }
    }
}
