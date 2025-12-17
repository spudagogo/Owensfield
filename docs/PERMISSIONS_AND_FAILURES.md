PERMISSIONS & FAILURE SCENARIOS
Owensfield Community Platform
Version 1.0 — LOCKED

This document is authoritative and derives directly from:

Owensfield Master Specification v1.0 (Locked)

If any conflict exists, this document and the Master Specification override implementation.

1. PERMISSION TEST MATRIX
1.1 Core Access
User Type	Members Area	Docs	Polls	Meetings	Actions	Comms	Finance
Inactive	❌	❌	❌	❌	❌	❌	❌
Active Member	✅	✅ (read)	✅	✅	✅ (view)	✅ (read)	✅ (view)
RG (no role)	✅	✅	✅	✅	✅ (view)	✅	✅
RG (elected role)	✅	✅	✅	✅	✅	✅	✅

Inactive members may access only Profile + Renewal.

1.2 Governance & Polls
Action	Active Member	RG (no role)	RG (elected role)
Suggest poll	✅	✅	✅
Vote	✅	✅	✅
Activate poll	❌	❌	✅ (≥4 RG approvals)
Close poll	❌	❌	✅ (≥4 RG approvals)

Poll ties:

No governance change applied

Poll archived as unresolved

1.3 Meetings, Agendas & Minutes
Action	Active Member	RG	RG (elected role)
View meetings	✅	✅	✅
Create meeting	❌	❌	✅
Submit agenda item	✅	✅	✅
Edit draft agenda/minutes	❌	❌	✅
Approve agenda/minutes	❌	❌	✅ (≥4 RG approvals)

Approved agendas and minutes are locked and archived.

1.4 Actions
Action	Active Member	RG	RG (elected role)
View	✅	✅	✅
Create / update	❌	❌	✅
Complete	❌	❌	✅

Completed actions are archived automatically.

1.5 Communications
Action	Active Member	RG	RG (elected role)
View	✅	✅	✅
Create thread	❌	❌	✅
Add updates/files	❌	❌	✅
Close / archive	❌	❌	✅
1.6 Documents
Action	Active Member	RG	RG (elected role)
View	✅	✅	✅
Upload	❌	❌	✅ (folder-restricted)
Edit archived	❌	❌	✅ (≥4 RG approvals)
Delete archived	❌	❌	✅ (≥4 RG approvals)
1.7 Membership Database

Access restricted to RG elected roles only
(Chair, Vice Chair, Secretary, Treasurer)

Actions:

Edit profile

Reset password

Archive user profile

Reassign plot owner (offline verification required)

2. FAILURE SCENARIOS (MANDATORY BEHAVIOUR)
RG drops below 4 members

Temporary Mode activates automatically

Chair / Vice Chair gain override authority

Overrides logged

Mode exits when RG ≥ 4

RG role changes

Elections may run at any time

Role changes take effect only at OCG meeting or AGM

Step-downs take effect only at those meetings

Uncontested nominations auto-elect but wait for enactment

Poll tie

No governance change applied

Poll archived as unresolved

Agenda submitted after close

Submission blocked

No pending approval created

Profile deletion

User archived

Plot preserved

Plot marked unregistered

Historical votes preserved

AGM date change

Existing annual report retained

New report generated relative to new AGM

Exactly one “current” report per AGM

END OF DOCUMENT
