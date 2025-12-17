
# Owensfield System & Design Guidelines
**Status: Authoritative**
**Applies to all Cursor generations for this repo**

---

## 1. General System Guidelines

These rules are mandatory.

- Follow **Owensfield Master Specification v1.0 (Locked)** at all times
- Follow **docs/PERMISSIONS_AND_FAILURES.md** as authoritative for access control and failure handling
- Do **not** invent features, roles, permissions, workflows, or UI affordances
- Do **not** relax or bypass server-side enforcement (RLS, RPCs, triggers)
- Do **not** hard-delete data — archive only
- Do **not** add discussion, comments, or chat features

### Code Structure
- Prefer **server-side enforcement** over frontend checks
- Use **Next.js App Router** conventions strictly
- Keep components small and composable
- Move helpers, guards, and logic into shared utilities where appropriate
- Avoid duplication of permission logic — reuse existing guards/helpers

### Layout & Responsiveness
- Use **flexbox and grid by default**
- Avoid absolute positioning unless explicitly required by design
- UI must remain usable at common breakpoints (mobile, tablet, desktop)

---

## 2. Owensfield Design System Guidelines

The visual system must match the Figma designs exactly in tone and hierarchy.

### Design Philosophy
- Calm, restrained, civic
- No flashy animations
- No playful or consumer-style UI
- Clarity > decoration

---

## 3. Color System (Semantic Usage Only)

Use semantic tokens only — never hardcode colors.

### Primary
- **Primary**: Used for key actions and identity accents  
  Examples:
  - Main CTA buttons
  - Active navigation indicators
  - Key highlights

### Secondary
- **Secondary**: Used for supporting actions
  Examples:
  - Secondary buttons
  - Subtle emphasis elements

### Accent / Muted
- Use for:
  - Background panels
  - Dividers
  - Non-critical UI elements

### Destructive
- Used **only** for:
  - Archive actions
  - Irreversible governance actions (still archived, never deleted)

---

## 4. Typography Guidelines

### Font Family
- Use the configured global font stack only
- Do not introduce additional fonts

### Headings
- Headings communicate structure, not decoration
- Avoid overly large or dramatic type
- Use consistent hierarchy:
  - Page title → Section title → Subsection title

### Body Text
- Clear, readable, neutral tone
- No playful language
- No emojis
- No conversational filler

---

## 5. Button System

### Primary Button
- One per section or screen
- Represents the main action
- Must be visually dominant

### Secondary Button
- Supporting actions
- May appear alongside primary

### Tertiary Button
- Text-only
- Used sparingly for low-priority actions

Rules:
- Never show more than one primary button per logical action group
- Button labels must be explicit and unambiguous
- Avoid vague labels (“OK”, “Confirm”, “Proceed”)

---

## 6. Forms & Inputs

- Labels are mandatory
- Helper text is preferred over placeholders
- Validation errors must be explicit and calm
- Do not auto-submit or auto-save without clear user intent

---

## 7. Navigation Rules

- Navigation reflects **role + membership state**
- Inactive members must never see protected navigation items
- RG admin items must never appear for non-elected users
- Do not hide permission failures silently — redirect safely

---

## 8. Governance & Admin UI Rules

- Governance actions must:
  - Be explicit
  - Show consequences
  - Require confirmation
- Approval thresholds must be visible where relevant
- Never imply immediate effect if enactment is delayed (OCG/AGM)

---

## 9. Documents & Records

- Everything is archival
- History is preserved
- Edits create revisions
- Deletions require approval and are archival only

---

## 10. What NOT To Do (Hard Stops)

- Do not redesign layouts without explicit instruction
- Do not “improve” UX beyond the Figma intent
- Do not introduce convenience shortcuts that bypass governance
- Do not guess missing rules — ask instead

---

**End of Guidelines**

  
