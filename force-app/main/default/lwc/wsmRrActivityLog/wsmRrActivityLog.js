import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import resetCounters from '@salesforce/apex/WSM_RR_AdminController.resetCounters';
import { reduceErrorMessage, timeAgo } from 'c/wsmRrUtils';

const STATUS_META = {
    ASSIGNED: { icon: 'utility:success', variant: 'success', label: 'Assigned' },
    FALLBACK: { icon: 'utility:warning', variant: 'warning', label: 'Fallback used' },
    NO_ELIGIBLE_MEMBERS: { icon: 'utility:error', variant: 'error', label: 'No eligible members' },
    GROUP_NOT_FOUND: { icon: 'utility:error', variant: 'error', label: 'Group not found' },
    GROUP_INACTIVE: { icon: 'utility:error', variant: 'error', label: 'Group inactive' },
    LOCK_TIMEOUT: { icon: 'utility:error', variant: 'error', label: 'Lock timeout' },
    ERROR: { icon: 'utility:error', variant: 'error', label: 'Error' }
};

/** Activity tab: per-member period bars + last-25 log list + Reset Counters. */
export default class WsmRrActivityLog extends LightningElement {
    @api groupId;
    @api members = [];
    @api recentLogs = [];
    @api periodLabel;

    showResetConfirm = false;

    get bars() {
        const list = this.members || [];
        const max = Math.max(1, ...list.map((m) => m.periodCount || 0));
        return list
            .slice()
            .sort((a, b) => (b.periodCount || 0) - (a.periodCount || 0))
            .map((m) => {
                const pct = Math.max((m.periodCount || 0) / max, 0) * 100;
                return {
                    memberId: m.memberId,
                    userName: m.userName,
                    periodCount: m.periodCount || 0,
                    fillStyle: `width:${pct}%`,
                    fillClass: 'al__barfill' + (m.active ? '' : ' al__barfill_inactive')
                };
            });
    }

    get hasBars() {
        return this.bars.length > 0;
    }

    get hasNoBars() {
        return !this.hasBars;
    }

    get logRows() {
        return (this.recentLogs || []).slice(0, 25).map((log) => {
            const meta = STATUS_META[log.status] || { icon: 'utility:info', variant: 'inverse', label: log.status };
            return {
                ...log,
                iconName: meta.icon,
                iconVariant: meta.variant,
                statusLabel: meta.label,
                relativeTime: timeAgo(log.timestampValue),
                hasRecordLink: !!log.assignedRecordId,
                recordUrl: log.assignedRecordId ? `/${log.assignedRecordId}` : undefined
            };
        });
    }

    get hasLogs() {
        return this.logRows.length > 0;
    }

    get hasNoLogs() {
        return !this.hasLogs;
    }

    openResetConfirm() {
        this.showResetConfirm = true;
    }

    closeResetConfirm() {
        this.showResetConfirm = false;
    }

    async doReset() {
        this.showResetConfirm = false;
        try {
            await resetCounters({ groupId: this.groupId });
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Counters reset', message: 'Rotation state cleared.', variant: 'success' })
            );
            this.dispatchEvent(new CustomEvent('refresh'));
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Reset failed', message: reduceErrorMessage(error), variant: 'error' })
            );
        }
    }
}
