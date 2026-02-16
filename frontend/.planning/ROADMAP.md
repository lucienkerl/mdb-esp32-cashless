# Project Roadmap - Vending Machine Management UI

## Overview

**Project**: Vending Machine Management UI  
**Scope**: v1 - 10-100 machine fleet management  
**Depth**: Standard  
**Total Phases**: 6  
**Total Requirements**: 25  

---

## Phases

- [ ] **Phase 1: Foundation & Auth** - Project setup with authentication and role-based access
- [ ] **Phase 2: Machine Dashboard** - Machine list, status, and remote control capabilities  
- [ ] **Phase 3: Stock Management** - Visual slot management and inventory control
- [ ] **Phase 4: Sales & Reporting** - Sales visibility, reports, and export
- [ ] **Phase 5: Price Management** - Remote price configuration and audit trail
- [ ] **Phase 6: Real-time & Polish** - Live updates, notifications, and final refinements

---

## Progress Tracker

| Phase | Plans | Status | Completed |
|-------|-------|--------|-----------|
| 1. Foundation & Auth | 0/6 | Planned | - |
| 2. Machine Dashboard | 0/0 | Not started | - |
| 3. Stock Management | 0/0 | Not started | - |
| 4. Sales & Reporting | 0/0 | Not started | - |
| 5. Price Management | 0/0 | Not started | - |
| 6. Real-time & Polish | 0/0 | Not started | - |

---

## Phase Details

### Phase 1: Foundation & Auth

**Goal**: Establish project foundation with authentication system and role-based access control

**Depends on**: Nothing (first phase)

**Requirements**: USER-01, USER-02, USER-03, USER-04

**Success Criteria** (what must be TRUE):
1. User can log in with email/password and session persists across page refreshes
2. User can log out from any page
3. Admin users see full navigation and can access all features
4. Operator users see restricted navigation and cannot access user management
5. Admin can create new users and assign Operator role with machine access
6. Operators only see machines explicitly assigned to them in the dashboard

**Plans**:
- [ ] `01-01-PLAN.md` — Initialize Nuxt 3 project with Supabase and shadcn-vue
- [ ] `01-02-PLAN.md` — Create database schema with RBAC tables and RLS policies
- [ ] `01-03-PLAN.md` — Implement authentication UI and flow
- [ ] `01-04-PLAN.md` — Build role-based navigation and access control
- [ ] `01-05-PLAN.md` — Create user management interface (Admin only)
- [ ] `01-06-PLAN.md` — Implement machine assignment system

**Wave Structure**:
- Wave 1 (Parallel): 01-01 (Project Setup), 01-02 (Database Schema)
- Wave 2 (Parallel): 01-03 (Auth Flow), 01-04 (Navigation)
- Wave 3 (Sequential): 01-05 (User Management), 01-06 (Machine Assignment)

---

### Phase 2: Machine Dashboard

**Goal**: Provide complete visibility and control over the vending machine fleet

**Depends on**: Phase 1

**Requirements**: MACH-01, MACH-02, MACH-03, MACH-04, MACH-05

**Success Criteria** (what must be TRUE):
1. User sees a grid/list of all machines with clear online (green) / offline (red) indicators
2. Machines can be grouped and filtered by location with expandable sections
3. Each location shows quick stats (total machines, online count)
4. Clicking a machine opens detail view with telemetry, status, and activity log
5. Admin can restart a machine remotely with confirmation and status feedback
6. Admin can enable/disable machines with visual state indication
7. Disabled machines show clear visual indicator across all views

**Plans**: TBD

---

### Phase 3: Stock Management

**Goal**: Enable visual inventory management with product catalog and stock alerts

**Depends on**: Phase 2

**Requirements**: STOCK-01, STOCK-02, STOCK-03, STOCK-04, STOCK-05

**Success Criteria** (what must be TRUE):
1. User sees 6×8 slot grid visualization clearly showing tray and slot numbers
2. Empty slots are visually distinct from filled slots
3. Each slot displays current stock quantity with visual level indicator (full/medium/low/empty)
4. Admin can trigger "Force Inventory" to reset all slots to max capacity with audit log
5. Product catalog allows adding/editing products with name, description, image, category
6. Products can be assigned/unassigned to slots
7. Low stock alerts appear visually on affected machines and in alert list
8. Alerts can be acknowledged and cleared

**Plans**: TBD

---

### Phase 4: Sales & Reporting

**Goal**: Deliver sales visibility with real-time feed, reports, and data export

**Depends on**: Phase 3

**Requirements**: SALES-01, SALES-02, SALES-03, SALES-04, SALES-05, SALES-06

**Success Criteria** (what must be TRUE):
1. Sales appear in real-time feed showing machine, product, price, timestamp without page refresh
2. Sales feed is filterable by machine and location
3. Daily/weekly/monthly reports show summary metrics (total sales, revenue, transactions)
4. Reports include breakdown by machine and location with period comparison
5. Bestsellers view ranks products by sales volume with revenue metrics
6. User can export filtered sales data to CSV with all relevant fields
7. Individual transaction details show complete sale record including slot and payment method
8. Revenue trends are visualized with charts showing totals by period

**Plans**: TBD

---

### Phase 5: Price Management

**Goal**: Enable remote price configuration with bulk updates and audit trail

**Depends on**: Phase 4

**Requirements**: PRICE-01, PRICE-02, PRICE-03, PRICE-04

**Success Criteria** (what must be TRUE):
1. User sees current prices for all slots in machine grid view with proper currency formatting
2. Admin can edit individual slot prices inline or via modal with validation
3. Price changes sync to machine via MQTT with success/error feedback
4. Bulk price updates allow selecting multiple slots with percentage or fixed adjustment
5. Bulk update preview shows changes before applying
6. Price history log shows timestamped changes with old/new values and user who made change
7. Price history is filterable by machine, slot, and date range

**Plans**: TBD

---

### Phase 6: Real-time & Polish

**Goal**: Deliver live updates across all features and refine UX

**Depends on**: Phase 5

**Requirements**: MACH-06, MACH-07

**Success Criteria** (what must be TRUE):
1. Machine online/offline status updates in real-time without page refresh
2. Connection status indicator shows realtime subscription health
3. Visual animation plays when machine status changes
4. Alert badge appears on machines with errors
5. Error details are viewable with acknowledge/clear actions
6. Alert history is maintained and viewable
7. UI is polished with consistent spacing, typography, and responsive behavior
8. Error handling provides clear user feedback for all error states

**Plans**: TBD

---

## Requirement Coverage

| Requirement | Phase | Description |
|-------------|-------|-------------|
| USER-01 | 1 | Authentication via Supabase Auth |
| USER-02 | 1 | Role-based access (Admin/Operator) |
| USER-03 | 1 | User management (Admin only) |
| USER-04 | 1 | Machine assignment for Operators |
| MACH-01 | 2 | View machine list with status |
| MACH-02 | 2 | Group machines by location |
| MACH-03 | 2 | View machine details |
| MACH-04 | 2 | Restart machines remotely |
| MACH-05 | 2 | Enable/disable machines |
| MACH-06 | 6 | Real-time status updates |
| MACH-07 | 6 | Error/alert notifications |
| STOCK-01 | 3 | Visual slot grid (6×8) |
| STOCK-02 | 3 | View stock levels |
| STOCK-03 | 3 | Force inventory reset |
| STOCK-04 | 3 | Product catalog management |
| STOCK-05 | 3 | Low stock alerts |
| SALES-01 | 4 | Real-time sales feed |
| SALES-02 | 4 | Periodic reports |
| SALES-03 | 4 | Bestsellers view |
| SALES-04 | 4 | CSV export |
| SALES-05 | 4 | Transaction details |
| SALES-06 | 4 | Revenue metrics |
| PRICE-01 | 5 | View prices |
| PRICE-02 | 5 | Change prices |
| PRICE-03 | 5 | Bulk price updates |
| PRICE-04 | 5 | Price history/audit log |

**Coverage**: 25/25 v1 requirements mapped ✓

---

## Dependency Chain

```
Phase 1: Foundation & Auth
    ↓
Phase 2: Machine Dashboard
    ↓
Phase 3: Stock Management
    ↓
Phase 4: Sales & Reporting
    ↓
Phase 5: Price Management
    ↓
Phase 6: Real-time & Polish
```

---

## Decision Log

| Date | Decision | Impact |
|------|----------|--------|
| 2026-02-16 | 6 phases for balanced delivery | Allows incremental feature delivery with dependencies respected |
| 2026-02-16 | Phase 6 dedicated to real-time | Realtime spans all features, consolidated for focused implementation |

---

## Notes

- Each phase delivers a working, testable increment
- Phases 2-6 build on previous work (vertical slicing)
- Phase 6 (Real-time) implements Supabase Realtime subscriptions that enhance all previous phases
- Success criteria are observable user behaviors, not implementation details
