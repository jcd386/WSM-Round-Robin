# WSM Round Robin

A professional round-robin assignment engine for Salesforce. Distribute leads, cases, opportunities — any records — across your team with configurable algorithms, capacity limits, out-of-office handling, queue fallback, and a full audit trail. Admins manage everything from a single app page; flows consume one invocable action.

Built by [We Summit Mountains](https://wesummitmountains.com).

## Installation

### Option A: Install the package (recommended — upgradeable)

Use the install URL for the latest released version:

```
https://login.salesforce.com/packaging/installPackage.apexp?p0=04tTP000000kbZFYAY
```

Or via CLI:

```bash
sf package install --package 04tTP000000kbZFYAY --target-org YOUR_ORG_ALIAS --wait 30
```

### Option B: Source deploy (not upgradeable)

[![Deploy to Salesforce](https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/src/main/webapp/resources/img/deploy.png)](https://githubsfdeploy.herokuapp.com/app/githubdeploy/jcd386/WSM-Round-Robin?ref=main)

```bash
git clone https://github.com/jcd386/WSM-Round-Robin.git
cd WSM-Round-Robin
sf project deploy start --target-org YOUR_ORG_ALIAS
```

## What gets installed

| Component | Name |
|-----------|------|
| Lightning app | **WSM Round Robin** (find it in the App Launcher) |
| Primary tab | **Round Robin Manager** — the whole admin experience lives here |
| Supporting tabs | **Round Robin Groups**, **Assignment Logs** (raw record access + reporting) |
| Objects | `WSM_Round_Robin_Group__c`, `WSM_Round_Robin_Member__c`, `WSM_Assignment_Log__c` |
| Permission sets | **WSM Round Robin Admin**, **WSM Round Robin User** (see Permissions below) |
| Flow action | **Round Robin: Get Assignee** (category "WSM Round Robin") |
| Template flow | **WSM - ALF - Round Robin: Example Assignment** (clone-me starter, ships inactive) |
| Reports | Folder **WSM Round Robin Reports**: Assignments by Member, Assignments by Group by Week |
| Utility bar | **Help & Flow Wiring** — in-app guidance on every tab of the app |

## Permissions — who needs what

The engine runs in **system context**. When a flow calls the assignment action, it works for *any* running user — sales reps, integration users, even unauthenticated guest users on web-to-lead — with **no permission set assigned**. Forgetting a permission set can never break your lead routing.

| Permission set | Who gets it | What it grants |
|----------------|-------------|----------------|
| **WSM Round Robin Admin** | People who create and manage groups | The WSM Round Robin app and all tabs, full access to the three objects, and the admin UI's Apex controller. Required to use the Round Robin Manager. |
| **WSM Round Robin User** | Optional — people who should *see* round robin data | Read access to groups/members and the assignment log, so they can open log records and run reports. Not required for assignments to work. |

Group members need neither — a user can receive assignments without ever logging in.

## Setup (2 minutes)

1. Assign **WSM Round Robin Admin** to yourself.
2. Open the **WSM Round Robin** app from the App Launcher → the **Round Robin Manager** tab greets you with a guided 3-step wizard: name the group and pick an algorithm, add members, activate.
3. Open the group's **Wiring** tab for copy-paste instructions to connect it to any Flow — pre-filled with the group's developer name.

## Assignment algorithms

| Algorithm | How it picks |
|-----------|--------------|
| **Strict Rotation** | Everyone gets equal turns, in order. The member who has waited longest goes next. |
| **Weighted** | Members with higher weights receive proportionally more assignments (stride scheduling — a weight-3 member gets 3x the volume of a weight-1 member). |
| **Least Assigned** | Whoever has the fewest assignments this period goes next. New members are calibrated to the pool median so they aren't flooded. |

Layered on top of any algorithm:

- **Period caps** — cap each member's assignments per day/week/month, with per-member overrides (0 = blocked).
- **Out of office** — date ranges per member; members are skipped while away and rejoin at the front of the rotation on return (no backlog dump).
- **Pause** — one-click active toggle per member or per group.
- **Fallback user or queue** — when nobody is eligible, requests route to a designated user *or queue* instead of failing. Queues work on queue-enabled objects (Leads, Cases, custom objects with queues).

## Using it from a Flow

Add the **Round Robin: Get Assignee** action to any flow (or clone the packaged template flow, which ships with the action plus a labeled decision path for every outcome):

- **Inputs**: `Group Developer Name` (stable key, survives sandbox refreshes — copy it from the group's Wiring tab) or `Group Id`; optional `Assigned Record Id` and `Context` for the audit log.
- **Outputs**:
  - **`Owner Id`** — the one to use: the assigned user, or the fallback queue. Drop it straight into your record's `OwnerId`.
  - `User Id` / `Queue Id` — the same result split by type, if your flow cares which it got.
  - `Status` — branch on it: `ASSIGNED`, `FALLBACK`, `NO_ELIGIBLE_MEMBERS`, `GROUP_INACTIVE`, `GROUP_NOT_FOUND`, `LOCK_TIMEOUT`, `ERROR`.
  - `Log Id` — the audit record written for this request.

From Apex:

```apex
WSM_RRResult result = WSM_RoundRobinService.assignByDeveloperName('sales_leads');
Id ownerId = result.ownerId;
```

## Why it's safe under load

- **Row locking**: the engine locks the group row (`FOR UPDATE`) so concurrent transactions serialize — no double-assignments under race.
- **Bulk-correct**: 200 records hitting the same group in one transaction advance the rotation 200 times (distinct assignees while the pool lasts), with a fixed footprint of ≤4 queries and 2 DML statements per transaction.
- **Explicit outcomes**: every request produces a status and an Assignment Log row — nothing fails silently.
- **No scheduled jobs**: caps and fairness counters are computed from the log on the fly; a "daily cap" resets because tomorrow's count starts at zero, not because a batch ran.

## Admin features

- **Test Assignment (dry run)** — see who would be assigned next and exactly why each other member was skipped ("Out of office until Aug 12", "At capacity 8/10"), without affecting the rotation. Optionally commit for real.
- **Activity view** — per-member fairness bars for the current period plus the latest assignment log entries.
- **Plain-language help** — every setting has an info bubble explaining what it does; the utility bar carries wiring guidance to every tab.
- **Assignment Logs** — a reportable object; two starter reports included.
- **Lifecycle chips** — `Members ✓ · Active ✓ · Wired ✓` tells you at a glance whether a group is fully operational.

## Objects

| Object | Purpose |
|--------|---------|
| `WSM_Round_Robin_Group__c` | A pool + its policy: algorithm, capacity mode, period, fallback user/queue |
| `WSM_Round_Robin_Member__c` | A user's seat in a group: weight, cap override, OOO dates, rotation state |
| `WSM_Assignment_Log__c` | Audit trail of every request — also the counting source for caps and fairness |

The ERD is in [docs/erd.drawio](docs/erd.drawio).

## License

MIT
