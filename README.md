# WSM Round Robin

A professional round-robin assignment engine for Salesforce. Distribute leads, cases, opportunities — any records — across your team with configurable algorithms, capacity limits, out-of-office handling, and a full audit trail. Admins manage everything from a single app page; flows consume one invocable action.

Built by [We Summit Mountains](https://wesummitmountains.com).

## Installation

### Option A: Install the package (recommended — upgradeable)

Use the install URL for the latest released version:

```
https://login.salesforce.com/packaging/installPackage.apexp?p0=INSTALL_04T_ID
```

Or via CLI:

```bash
sf package install --package INSTALL_04T_ID --target-org YOUR_ORG_ALIAS --wait 30
```

### Option B: Source deploy (not upgradeable)

[![Deploy to Salesforce](https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/src/main/webapp/resources/img/deploy.png)](https://githubsfdeploy.herokuapp.com/app/githubdeploy/jcd386/WSM-Round-Robin?ref=main)

```bash
git clone https://github.com/jcd386/WSM-Round-Robin.git
cd WSM-Round-Robin
sf project deploy start --target-org YOUR_ORG_ALIAS
```

## Setup (2 minutes)

1. Assign the **WSM Round Robin Admin** permission set to whoever manages groups.
2. Assign the **WSM Round Robin User** permission set to any user whose flows will call the engine (including integration/automation users).
3. Open the **WSM Round Robin** app → the guided wizard walks you through your first group: pick an algorithm, add members, activate.
4. Open the group's **Wiring** tab for copy-paste instructions to connect it to any Flow.

## Assignment algorithms

| Algorithm | How it picks |
|-----------|--------------|
| **Strict Rotation** | Everyone gets equal turns, in order. The member who has waited longest goes next. |
| **Weighted** | Members with higher weights receive proportionally more assignments (stride scheduling — a weight-3 member gets 3x the volume of a weight-1 member). |
| **Least Assigned** | Whoever has the fewest assignments this period goes next. New members are calibrated to the pool median so they aren't flooded. |

Layered on top of any algorithm:

- **Period caps** — cap each member's assignments per day/week/month, with per-member overrides (0 = blocked). Everyone at cap? Requests route to the group's **fallback user**, or return a `NO_ELIGIBLE_MEMBERS` status your flow can branch on.
- **Out of office** — date ranges per member; members are skipped while away and rejoin at the front of the rotation on return (no backlog dump).
- **Pause** — one-click active toggle per member or per group.

## Using it from a Flow

Add the **Round Robin: Get Assignee** action to any flow:

- **Input**: `Group Developer Name` (stable key, survives sandbox refreshes) or `Group Id`; optional `Assigned Record Id` and `Context` for the audit log.
- **Outputs**: `User Id` (the assignee), `Status` (`ASSIGNED`, `FALLBACK`, `NO_ELIGIBLE_MEMBERS`, `GROUP_INACTIVE`, `GROUP_NOT_FOUND`, `LOCK_TIMEOUT`, `ERROR`), `Log Id`.

Branch on `Status`, then set your record's `OwnerId` from `User Id`. An inactive template flow (`WSM_ALF_Round_Robin_Example_Assignment`) ships with the package — clone it as a starting point.

From Apex:

```apex
WSM_RRResult result = WSM_RoundRobinService.assignByDeveloperName('sales_leads');
```

## Why it's safe under load

- **Row locking**: the engine locks the group row (`FOR UPDATE`) so concurrent transactions serialize — no double-assignments under race.
- **Bulk-correct**: 200 records hitting the same group in one transaction advance the rotation 200 times (distinct assignees while the pool lasts), with a fixed footprint of ≤4 queries and 2 DML statements per transaction.
- **Explicit outcomes**: every request produces a status and an Assignment Log row — nothing fails silently.

## Admin features

- **Test Assignment (dry run)** — see who would be assigned next and exactly why each other member was skipped ("Out of office until Aug 12", "At capacity 8/10"), without affecting the rotation. Optionally commit for real.
- **Activity view** — per-member fairness bars for the current period plus the latest assignment log entries.
- **Assignment Logs** — a reportable object; two starter reports included (Assignments by Member, Assignments by Group by Week).
- **Lifecycle chips** — `Members ✓ · Active ✓ · Wired ✓` tells you at a glance whether a group is fully operational.

## Objects

| Object | Purpose |
|--------|---------|
| `WSM_Round_Robin_Group__c` | A pool + its policy: algorithm, capacity mode, period, fallback user |
| `WSM_Round_Robin_Member__c` | A user's seat in a group: weight, cap override, OOO dates, rotation state |
| `WSM_Assignment_Log__c` | Audit trail of every request — also the counting source for caps and fairness |

The ERD is in [docs/erd.drawio](docs/erd.drawio).

## License

MIT
