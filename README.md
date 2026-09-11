# WSM Round Robin

A professional round-robin assignment engine for Salesforce. Distribute leads, cases, opportunities, or any records across your team with configurable algorithms, capacity limits measured against your own data, out-of-office handling, overflow benches, queue fallback, and a full audit trail. Admins manage everything from a single app page; flows consume one invocable action.

Built by [We Summit Mountains](https://wesummitmountains.com).

## Installation

### Option A: Install the package (recommended, upgradeable)

[![Install Unlocked Package](https://img.shields.io/badge/Install-Unlocked%20Package-blue?logo=salesforce)](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tTP000000kbZFYAY)

- **Production / Developer Edition**: https://login.salesforce.com/packaging/installPackage.apexp?p0=04tTP000000kbZFYAY
- **Sandbox**: https://test.salesforce.com/packaging/installPackage.apexp?p0=04tTP000000kbZFYAY

Install for **All Users** or **Admins Only**, then assign the permission set below. Upgrading later is a matter of installing the next version over the top; your groups, members and logs are preserved.

### Option B: Source deploy (not upgradeable)

```bash
git clone https://github.com/jcd386/WSM-Round-Robin.git
cd WSM-Round-Robin
sf project deploy start -o <your-org-alias> -l RunSpecifiedTests \
  -t WSM_RoundRobinEngine_Test -t WSM_Strategies_Test -t WSM_CapacityQuery_Test \
  -t WSM_CapacityEngine_Test -t WSM_RoundRobinService_Test \
  -t WSM_RoundRobinInvocable_Test -t WSM_RR_AdminController_Test \
  -t WSM_MemberTriggerHandler_Test
```

## What gets installed

| Component | Name |
|-----------|------|
| Lightning app | **WSM Round Robin** (find it in the App Launcher) |
| Primary tab | **Round Robin Manager**, where the whole admin experience lives |
| Supporting tabs | **Round Robin Groups**, **Assignment Logs** (raw record access + reporting) |
| Objects | `WSM_Round_Robin_Group__c`, `WSM_Round_Robin_Member__c`, `WSM_Capacity_Query__c`, `WSM_Capacity_Filter__c`, `WSM_Assignment_Log__c` |
| Permission sets | **WSM Round Robin Admin**, **WSM Round Robin User** (see Permissions below) |
| Flow action | **Round Robin: Get Assignee** (category "WSM Round Robin") |
| Template flow | **WSM - ALF - Round Robin: Example Assignment** (clone-me starter, ships inactive) |
| Reports | Folder **WSM Round Robin Reports**: Assignments by Member, Assignments by Group by Week |
| Utility bar | **Help & Flow Wiring**, in-app guidance on every tab of the app |

## Permissions: who needs what

The engine runs in **system context**. When a flow calls the assignment action, it works for *any* running user, including sales reps, integration users, and unauthenticated guest users on web-to-lead, with **no permission set assigned**. Forgetting a permission set can never break your lead routing.

| Permission set | Who gets it | What it grants |
|----------------|-------------|----------------|
| **WSM Round Robin Admin** | People who create and manage groups | The WSM Round Robin app and all tabs, full access to the package objects, and the admin UI's Apex controller. Required to use the Round Robin Manager. |
| **WSM Round Robin User** | Optional, for people who should *see* round robin data | Read access to groups, members, capacity config and the assignment log, so they can open log records and run reports. Not required for assignments to work. |

Group members need neither. A user can receive assignments without ever logging in.

### What the engine reads

Worth stating plainly, because Capacity Queries widened this. The engine reads and writes its own package objects freely. Against **your** objects it does exactly two things, both in system mode:

1. **Counts.** A capacity query runs a `COUNT(Id)` aggregate grouped by an owner field. It returns tallies, never record content. There is no code path in the query builder that can emit a field value from the records being counted.
2. **One lookup on the record you handed it.** If a capacity query draws its value from the record being routed, the engine reads the fields that capacity query names, only from the record Id your flow passed as `Assigned Record Id`. Those values build the count and are never written to the audit log.

Both are system mode on purpose. In the guest and community contexts this package is built for, the running user frequently cannot read the record they just created, so a user-mode count would come back zero and silently misroute.

## Setup (2 minutes)

1. Assign **WSM Round Robin Admin** to yourself.
2. Open the **WSM Round Robin** app from the App Launcher. The **Round Robin Manager** tab greets you with a guided 3-step wizard: name the group and pick an algorithm, add members, activate.
3. Open the group's **Wiring** tab for copy-paste instructions to connect it to any Flow, pre-filled with the group's developer name.

## Assignment algorithms

| Algorithm | How it picks |
|-----------|--------------|
| **Strict Rotation** | Everyone gets equal turns, in order. The member who has waited longest goes next. |
| **Weighted** | Members with higher weights receive proportionally more assignments (stride scheduling: a weight-3 member gets 3x the volume of a weight-1 member). |
| **Least Assigned** | Whoever has the fewest assignments *from this tool* this period goes next. New members are calibrated to the pool median so they are not flooded. |
| **Least Loaded** | Whoever carries the least **existing work in your org** goes next, measured by the group's Load Metric capacity queries and divided by member weight. Needs at least one Load Metric capacity query; without one it falls back to Strict Rotation and says so on the log. |

Layered on top of any algorithm:

- **Capacity queries**, described below: caps and load measured against your own records.
- **Period caps**: cap each member's assignments per day, week or month, with per-member overrides (0 blocks the member).
- **Tiers**: a primary pool and an overflow bench. See below.
- **Out of office**: date ranges per member. Members are skipped while away and rejoin at the front of the rotation on return, with no backlog dump.
- **Pause**: one-click active toggle per member or per group.
- **Fallback user or queue**: when nobody is eligible, requests route to a designated user *or* queue instead of failing. Queues work on queue-enabled objects (Leads, Cases, custom objects with queues).

## Capacity queries: capping and balancing on your own data

"Least Assigned" counts what this tool handed out. That is often the wrong number. What you usually care about is how much work somebody is *actually holding*, including work that arrived from anywhere else.

A **capacity query** is an admin-defined count of existing records, built from dropdowns in the Capacity tab. For example: *Accounts where Employer Status is Contracted or Pending Schedule, owned by this member.*

Each one has a **role**:

| Role | What it does |
|------|--------------|
| **Cap** | Blocks the member once the count reaches the cap. The skip reason reads "At capacity on Open Accounts (38/20)". |
| **Load Metric** | Feeds the Least Loaded algorithm's ranking, so the member holding the least work wins. |
| **Cap and Load Metric** | Both, from a single query. |

You build the filters the way you build them in Flow: a list of rows plus optional filter logic like `1 AND (2 OR 3)`. Each filter row takes a field, an operator (equals, in, greater than, starts with, is null, and the rest) and a value. The value can come from three places:

- **Literal**: a value you type, offered as a picklist when the field has one.
- **Relative Date**: a Salesforce date literal such as `LAST_N_DAYS:30`. **This is how you keep a count honest.** A cap on "leads still sitting in Introduced" with no time window is a one-way ratchet: it only ever grows, and the day someone crosses it they are locked out permanently. Add a rolling window and the count drains on its own.
- **Routed Record Field**: a value read off the record being routed, which lets a cap depend on the incoming record. For example, cap each member at 3 accounts *sharing the renewal date of the lead being assigned*. Supports the `equals` operator, because the count is grouped by that value.

### Fractional shares

Member **Weight** does double duty. Under Least Loaded, load is divided by weight, so weight 3 against weight 1 settles at roughly three assignments to one. That is how you say "only give this person every third one" without maintaining a counter anywhere.

### It is safe by construction

The capacity editor is the only place in the package that builds a query at runtime, so the whole injection surface is one class with one job. Object and field names are resolved through the schema describe and the describe's own name is what reaches the query, never the typed string. Operators come from a closed list mapped to fixed fragments. Every value is a bind variable. Date literals, which SOQL cannot bind, are matched against a whitelist before being inlined. Filter logic is tokenized and rejected unless every token is a real filter number, `AND`, `OR`, or a parenthesis. A capacity query that fails any of that is reported to the admin and skipped, never guessed at.

### Limits and failure behavior

- Five active capacity queries per group. Past that, the extras are skipped and the log says so.
- One aggregate query per capacity query, **regardless of pool size**. A five-person pool and a fifty-person pool cost the same.
- Only one filter per capacity query may read from the routed record.
- A capacity query that will not compile is reported as a warning on the assignment log and in the simulator, and is then ignored. A broken count never blocks routing for the whole group, because silently routing nobody is worse than routing and saying why.

## Tiers: a primary pool and an overflow bench

Give each member a **Tier**. The engine fills the lowest tier that has anyone eligible and stops there. Tier 1 is your primary pool; tier 2 is the bench that only gets touched when everyone on tier 1 is capped, away or paused. Blank counts as tier 1, so existing groups behave exactly as before.

Every gate still applies inside a tier. A bench member who is over their cap is still skipped, and the group falls through to the fallback rather than dumping the work on somebody who has no room for it. When a pick comes from a later tier, the assignment log records "Filled from tier 2", so you can see the bench being leaned on before it becomes a problem.

## Using it from a Flow

Add the **Round Robin: Get Assignee** action to any flow (or clone the packaged template flow, which ships with the action plus a labeled decision path for every outcome):

- **Inputs**: `Group Developer Name` (stable key, survives sandbox refreshes, copy it from the group's Wiring tab) or `Group Id`; optional `Assigned Record Id` and `Context` for the audit log. Pass `Assigned Record Id` whenever a capacity query reads from the routed record.
- **Outputs**:
  - **`Owner Id`**, the one to use: the assigned user, or the fallback queue. Drop it straight into your record's `OwnerId`.
  - `User Id` / `Queue Id`, the same result split by type, if your flow cares which it got.
  - `Status`, to branch on: `ASSIGNED`, `FALLBACK`, `NO_ELIGIBLE_MEMBERS`, `GROUP_INACTIVE`, `GROUP_NOT_FOUND`, `LOCK_TIMEOUT`, `ERROR`.
  - `Log Id`, the audit record written for this request.

From Apex:

```apex
WSM_RRResult result = WSM_RoundRobinService.assignByDeveloperName('sales_leads');
Id ownerId = result.ownerId;
```

## Why it's safe under load

- **Row locking**: the engine locks the group row (`FOR UPDATE`) so concurrent transactions serialize. No double-assignments under race.
- **Bulk-correct**: 200 records hitting the same group in one transaction advance the rotation 200 times, with distinct assignees while the pool lasts. Load metrics are charged in memory as each pick is made, so a bulk insert levels across the pool instead of handing every record to whoever was cheapest when the batch started. The counted records do not exist until commit, which is exactly why that matters.
- **Flat query footprint**: independent of both batch size and pool size. Per call: up to 2 resolve/lock, 1 member, up to 3 period aggregates, 1 capacity config, one aggregate per active capacity query, and at most one routed-record read per object type, plus one member update and one log insert.
- **Explicit outcomes**: every request produces a status and an Assignment Log row. Nothing fails silently.
- **No scheduled jobs**: caps and fairness counters are computed on the fly. A "daily cap" resets because tomorrow's count starts at zero, not because a batch ran.

## Admin features

- **Test Assignment (dry run)**: see who would be assigned next and exactly why each other member was skipped ("Out of office until Aug 12", "At capacity on Open Accounts 38/20"), without affecting the rotation. Shows each member's live capacity readings, their load score, their tier, and which tier the pick came from. Optionally commit for real.
- **Capacity tab**: build counts from dropdowns, with live validation. The editor compiles your draft with the same compiler the engine uses and tells you whether it will work before you save it, so a misconfiguration surfaces in week one instead of month three.
- **Activity view**: per-member fairness bars for the current period plus the latest assignment log entries.
- **Plain-language help**: every setting has an info bubble explaining what it does; the utility bar carries wiring guidance to every tab.
- **Assignment Logs**: a reportable object, with two starter reports included.
- **Lifecycle chips**: `Members ✓ · Active ✓ · Wired ✓` tells you at a glance whether a group is fully operational.

## Objects

| Object | Purpose |
|--------|---------|
| `WSM_Round_Robin_Group__c` | A pool plus its policy: algorithm, capacity mode, period, fallback user/queue |
| `WSM_Round_Robin_Member__c` | A user's seat in a group: weight, tier, cap override, OOO dates, rotation state |
| `WSM_Capacity_Query__c` | One admin-defined count of your records, used as a cap and/or a load metric |
| `WSM_Capacity_Filter__c` | One filter row on a capacity query: field, operator, value source, value |
| `WSM_Assignment_Log__c` | Audit trail of every request, and the counting source for period caps and fairness |

The ERD is in [docs/erd.drawio](docs/erd.drawio).

## License

MIT
