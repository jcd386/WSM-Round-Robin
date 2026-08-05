import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import simulate from '@salesforce/apex/WSM_RR_AdminController.simulate';
import { reduceErrorMessage } from 'c/wsmRrUtils';

const STATUS_TEXT = {
    ASSIGNED: (name) => `Would assign: ${name}`,
    FALLBACK: (name) => `Would assign: ${name} (fallback)`,
    NO_ELIGIBLE_MEMBERS: () => 'No eligible member found'
};

const STATUS_DETAIL = {
    FALLBACK: 'No member currently passes the eligibility gates, so the group’s fallback user was selected instead.',
    NO_ELIGIBLE_MEMBERS: 'No member is currently eligible and no fallback user is configured on this group. A live call would return NO_ELIGIBLE_MEMBERS.'
};

/** Simulator modal: dry-run preview, per-member verdicts, optional commit. */
export default class WsmRrSimulator extends LightningElement {
    @api groupId;
    @api groupName;

    commit = false;
    isRunning = false;
    result;

    get runLabel() {
        return this.isRunning ? 'Running…' : 'Run';
    }

    get hasResult() {
        return !!this.result;
    }

    get hasNoResult() {
        return !this.result;
    }

    get resultTitle() {
        if (!this.result) {
            return '';
        }
        const fn = STATUS_TEXT[this.result.status];
        return fn ? fn(this.result.wouldAssignUserName) : `Status: ${this.result.status}`;
    }

    get resultDetail() {
        return this.result ? STATUS_DETAIL[this.result.status] : '';
    }

    get resultIcon() {
        if (!this.result) {
            return 'utility:info';
        }
        return this.result.status === 'ASSIGNED' ? 'utility:success' : 'utility:warning';
    }

    get resultVariant() {
        if (!this.result) {
            return 'inverse';
        }
        return this.result.status === 'ASSIGNED' ? 'success' : 'warning';
    }

    get resultCardClass() {
        const base = 'sim__resultcard';
        if (!this.result) {
            return base;
        }
        return this.result.status === 'ASSIGNED' ? `${base} sim__resultcard_ok` : `${base} sim__resultcard_warn`;
    }

    get committedLogId() {
        return this.result && this.result.committed ? this.result.logId : null;
    }

    get committedLogUrl() {
        return this.committedLogId ? `/${this.committedLogId}` : undefined;
    }

    get verdictRows() {
        if (!this.result || !this.result.verdicts) {
            return [];
        }
        return this.result.verdicts.map((v) => ({
            ...v,
            icon: v.eligible ? 'utility:success' : 'utility:close',
            variant: v.eligible ? 'success' : 'error',
            skipReason: v.eligible ? '—' : v.skipReason || 'Not eligible'
        }));
    }

    handleCommitToggle(event) {
        this.commit = event.target.checked;
    }

    async handleRun() {
        this.isRunning = true;
        try {
            this.result = await simulate({ groupId: this.groupId, commitAssignment: this.commit });
            if (this.result.committed) {
                this.dispatchEvent(
                    new ShowToastEvent({ title: 'Assignment committed', message: `Log ${this.result.logId}`, variant: 'success' })
                );
                this.dispatchEvent(new CustomEvent('refresh'));
            }
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Simulation failed', message: reduceErrorMessage(error), variant: 'error' })
            );
        } finally {
            this.isRunning = false;
        }
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }
}
