import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/** Wiring tab: numbered copy-paste flow guide pre-filled with the group's developer name. */
export default class WsmRrWiringPanel extends LightningElement {
    @api grp = {};

    showDevBlock = false;

    get devName() {
        return this.grp && this.grp.developerName ? this.grp.developerName : '(save the group to generate one)';
    }

    get apexSnippet() {
        return `WSM_RoundRobinService.assignByDeveloperName('${this.grp && this.grp.developerName ? this.grp.developerName : 'group_dev_name'}');`;
    }

    get devIconName() {
        return this.showDevBlock ? 'utility:chevrondown' : 'utility:chevronright';
    }

    toggleDevBlock() {
        this.showDevBlock = !this.showDevBlock;
    }

    copy(text) {
        if (navigator.clipboard) {
            navigator.clipboard.writeText(text);
        }
        this.dispatchEvent(new ShowToastEvent({ title: 'Copied', variant: 'success' }));
    }

    handleCopyDevName() {
        this.copy(this.grp && this.grp.developerName ? this.grp.developerName : '');
    }

    handleCopyApex() {
        this.copy(this.apexSnippet);
    }
}
