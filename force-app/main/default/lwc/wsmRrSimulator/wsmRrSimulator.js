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
    @api algorithm;

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

    get hasWarnings() {
        return !!(this.result && this.result.warnings && this.result.warnings.length);
    }

    get warningRows() {
        if (!this.result || !this.result.warnings) {
            return [];
        }
        return this.result.warnings.map((w, idx) => ({ key: idx, text: w }));
    }

    get showAssignedFromTier() {
        return !!(this.result && this.result.assignedFromTier > 1);
    }

    get assignedFromTierLabel() {
        return this.result ? `Filled from tier ${this.result.assignedFromTier}` : '';
    }

    get showExternalLoadColumn() {
        return this.algorithm === 'Least Loaded';
    }

    get verdictRows() {
        if (!this.result || !this.result.verdicts) {
            return [];
        }
        return this.result.verdicts.map((v) => this.buildVerdictRow(v));
    }

    buildVerdictRow(v) {
        const notNeeded = v.tierReached === false;
        let icon;
        let variant;
        let reasonText;
        if (notNeeded) {
            icon = 'utility:dash';
            variant = undefined;
            reasonText = 'Not needed for this pick';
        } else if (v.eligible) {
            icon = 'utility:success';
            variant = 'success';
            reasonText = 'Eligible';
        } else {
            icon = 'utility:close';
            variant = 'error';
            reasonText = v.skipReason || 'Not eligible';
        }
        return {
            memberId: v.memberId,
            userName: v.userName,
            tier: v.tier,
            icon,
            variant,
            reasonText,
            externalLoadLabel: v.externalLoad != null ? this.formatLoad(v.externalLoad) : '',
            capacityChips: (v.capacity || []).map((c) => this.buildCapacityChip(c)),
            hasCapacity: !!(v.capacity && v.capacity.length),
            rowClass: 'sim__row' + (notNeeded ? ' sim__row_notneeded' : '')
        };
    }

    formatLoad(n) {
        const num = Number(n);
        return Number.isInteger(num) ? String(num) : num.toFixed(1);
    }

    buildCapacityChip(c) {
        if (c.unavailableReason) {
            return {
                key: c.capacityQueryId || c.label,
                text: `${c.label}: ${c.unavailableReason}`,
                cls: 'sim__capchip sim__capchip_unavailable'
            };
        }
        const countText = c.cap != null ? `${c.count} / ${c.cap}` : String(c.count);
        return {
            key: c.capacityQueryId || c.label,
            text: `${c.label} ${countText}`,
            cls: 'sim__capchip' + (c.atCap ? ' sim__capchip_atcap' : '')
        };
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
