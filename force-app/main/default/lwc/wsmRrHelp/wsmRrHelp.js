import { LightningElement } from 'lwc';

/** Utility bar: compact accordion — what it is, quick start, generic wiring guide, permissions. */
export default class WsmRrHelp extends LightningElement {
    activeSection = 'quickstart';

    handleToggle(event) {
        this.activeSection = event.detail.openSections;
    }
}
