# Owensfield Community Platform  
## Governance Versioning Policy  
### Version 1.0 (Aligned to Master Specification v1.0 — Locked)

---

## 1. Purpose of This Policy

This policy defines **how changes to governance, rules, and platform behaviour are proposed, approved, versioned, and implemented** after the initial release.

Its purpose is to:
- Prevent silent or informal rule changes
- Maintain transparency and trust
- Ensure the platform evolves in a controlled, auditable way

This policy applies to **all future versions** (v1.1, v2.0, etc.).

---

## 2. What “Governance Versioning” Means

A **governance version** represents a complete, approved set of rules that define:
- How decisions are made
- Who has authority
- What approvals are required
- How records are preserved

At launch:
- The system is operating under **Governance v1.0**
- This corresponds exactly to **Master Specification v1.0 (Locked)**

---

## 3. What Requires a Governance Version Change

A new governance version is required for **any change** that affects:

- Voting rules or thresholds
- Role powers or responsibilities
- Approval requirements
- Membership eligibility or status rules
- Plot or voting-weight logic
- Document retention or archiving rules
- Temporary Mode behaviour
- Any rule that affects member rights or governance outcomes

> If a change alters *who can do what, when, or with whose approval*, it is a governance change.

---

## 4. What Does NOT Require a Governance Version Change

The following do **not** require a governance version change:

- Bug fixes that restore intended behaviour
- UI improvements that do not alter permissions or outcomes
- Performance or infrastructure changes
- Accessibility improvements
- Internal refactoring with no behaviour change

These may be released independently but must **not** change governance behaviour.

---

## 5. Governance Change Lifecycle

All governance changes follow the same lifecycle.

### Step 1 — Proposal
- Any **active member** may suggest a governance change
- The proposal must:
  - Clearly state the current rule
  - Clearly state the proposed change
  - Explain the reason for change

---

### Step 2 — RG Review
- The Representative Group reviews the proposal
- RG may:
  - Clarify wording
  - Combine related proposals
  - Decline proposals that are out of scope

---

### Step 3 — Governance Poll
- A formal **governance poll** is created
- Requires **at least 4 RG approvals** to activate
- Poll must clearly state:
  - The version being changed (e.g. v1.0 → v1.1)
  - The exact rule changes

---

### Step 4 — Community Vote
- Active members vote
- Voting uses standard plot-based voting rules
- Poll runs for the defined duration

---

### Step 5 — Automatic Application
If the poll passes:
- The governance change:
  - Takes effect automatically
  - Is logged
  - Is archived
- A new governance version number is assigned

If the poll fails or ties:
- No change is applied
- The current version remains in effect

---

## 6. Version Numbering Scheme

Governance versions use **semantic-style numbering**:

- **Major version** (v2.0, v3.0):
  - Fundamental governance changes
  - Structural changes to roles or voting
- **Minor version** (v1.1, v1.2):
  - Refinements or clarifications
  - Additions that do not overhaul structure

Version numbers are:
- Sequential
- Never reused
- Never deleted

---

## 7. Documentation Requirements

Every governance version must include:

- Updated **Master Specification**
- Updated **Governance Operating Guide**
- Updated **Permissions & Failure Scenarios** (if affected)

All documents must:
- Be committed to the repository
- Clearly state the version number
- Reference the governance poll that approved them

---

## 8. Effective Date of Changes

Governance changes:
- Take effect immediately upon poll approval **unless explicitly stated otherwise**
- Are reflected in the Governance dashboard
- Are recorded in the Documents archive

No retroactive changes are allowed.

---

## 9. Emergency Changes

There are **no emergency governance changes** outside the defined process.

Temporary Mode:
- Allows continuity of operation
- Does **not** allow permanent rule changes

If an emergency reveals a governance flaw:
- A governance poll must still be run
- The existing rules remain in force until approved otherwise

---

## 10. Audit & Transparency

For every governance version change, the platform will retain:

- The approving poll
- The vote outcome
- The exact rule changes
- The effective date
- The superseded version

Members can always see:
- The current governance version
- Past versions and when they applied

---

## 11. Prohibited Practices

The following are explicitly prohibited:

- Informal rule changes
- “Temporary” rules that are not polled
- Admin-only rule changes
- Off-platform decisions that contradict platform governance
- Editing historical governance records

---

## 12. Final Statement

Governance versioning exists to ensure that:

- Rules change only with consent
- Power shifts are visible
- History is preserved
- Trust is maintained over time

If a change cannot pass a governance poll, it **must not happen**.

---

**End of Governance Versioning Policy v1.0**
