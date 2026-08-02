# CodingInnovators Platform — Architecture

> Last updated: 2026-08-02

---

## Vision

Multi-tenant B2B SaaS platform. A **tenant** (workspace) subscribes, enables modules, and
operates within that module set. The platform provides identity, billing, workflow orchestration,
and developer tooling. Business logic lives in pluggable modules.

---

## Repository Layout

```
CI.Kernel                   ← shared contracts NuGet (IEvent, Result, BaseEntity, attributes)
CI.Infra                    ← Docker Compose, Helm, k8s, deploy workflows, monitoring config

Platform/
  CI.Platform.Gateway       ← YARP reverse proxy, JWT validation, tenant-role injection
  CI.Platform.Identity      ← (planned) Keycloak wrapper / identity management API
  CI.Platform.Tenants       ← tenant CRUD, module enable/disable, system-admin endpoints
  CI.Platform.Users         ← users, memberships, invitations, permissions
  CI.Platform.Billing       ← subscription plans, us ↔ tenant billing (Stripe)
  CI.Platform.Workflow      ← business process orchestration (see below)
  CI.Platform.DevTools      ← (planned) developer/debugging utilities

Modules/ (business domains — per-tenant)
  CI.Module.Payments        ← tenant ↔ their customers
  CI.Module.Accounting
  CI.Module.Booking
  CI.Module.Catalog
  CI.Module.HR
  CI.Module.Invoicing
  CI.Module.Legal
  CI.Module.Parties
  CI.Module.Tasks
  CI.Module.Warehouse

Connectors/
  CI.Connector.Slack
  CI.Connector.ComarchOptima
  ...

Clients/
  CI.Client.Portal          ← Angular (management portal)
  CI.Client.Mobile          ← Flutter (customer + manage app)
  CI.Client.Public          ← Astro (marketing / public booking entry)
```

---

## Service Pattern (every platform service and module)

```
CI.Platform.<Name>.Domain         — entities, enums (no EF, no external deps)
CI.Platform.<Name>.Infrastructure — DbContext, migrations, repositories
CI.Platform.<Name>.Core           — command/query handlers, DTOs
CI.Platform.<Name>.API            — controllers, Program.cs, DI wiring
tests/
  CI.Platform.<Name>.Tests        — in-memory EF, xUnit, inherits ModuleArchitectureTests
```

---

## Request Flow

```
External client
  → CI.Platform.Gateway (port 80)
      validates JWT (Keycloak)
      strips spoofed X-Tenant-Role header
      calls Users /internal/membership → injects X-Tenant-Role
      proxies to target service
  → CI.Platform.Tenants / CI.Platform.Users / CI.Module.*
```

Internal service-to-service calls bypass the gateway — direct HTTP on the Docker network.

---

## Event / Workflow Architecture

### Decision (2026-08-02)

**Events that cross service boundaries live in CI.Kernel.**
Events internal to a single service stay in that service's Domain assembly.

### Why CI.Platform.Workflow exists

Instead of loose MassTransit consumers scattered across services, `CI.Platform.Workflow`
is a **dedicated orchestration service** that:

- Stores workflow definitions (directed graphs / step sequences)
- Tracks workflow instances and their current state
- Executes steps, waits for conditions (events, timers, human approval)
- Provides an API + UI to inspect "tenant X is at step 2 of onboarding"
- Retries failed steps, handles timeouts, sends notifications at each stage

### How it works

```
TenantCreatedEvent (in CI.Kernel)
  → CI.Platform.Workflow receives it
      → starts "Tenant Onboarding" workflow instance
          Step 1: send welcome email          (HTTP call to Notification)
          Step 2: wait for FirstLoginEvent    (pause until event arrives)
          Step 3: provision default data      (HTTP call to Provisioning)
          Step 4: after 24h send tips email   (timer-based step)
```

Other services **do not know about each other**. They only:
- Expose internal APIs for Workflow to call
- Emit events to RabbitMQ

Workflow is the single place where business processes are defined and observable.

### Rule

Every write operation (command handler) **must** publish an event to RabbitMQ.
Use `[NoEvent("reason")]` attribute on the handler to explicitly opt out — the
architecture test will fail if neither is present.

---

## Architecture Rules (enforced by CI.Kernel.ArchTests)

| Rule | Enforced by |
|---|---|
| Domain must not reference Core/Infra/API | `ModuleArchitectureTests` |
| Core must not reference Infra/API | `ModuleArchitectureTests` |
| Controllers must not inject DbContext | `ModuleArchitectureTests` |
| Controllers must have `[Authorize]` or `[AllowAnonymous]` | `ModuleArchitectureTests` |
| Controllers must have `[RequireModule]` or `[AllowWithoutModule]` | `ModuleArchitectureTests` |
| Events must end with `Event` | `ModuleArchitectureTests` |
| Service classes must be sealed | `ModuleArchitectureTests` |
| Cross-boundary events must live in CI.Kernel | `ModuleArchitectureTests` (planned) |
| Command handlers must inject IEventBus or carry `[NoEvent]` | `ModuleArchitectureTests` (planned) |

---

## Infrastructure (live on DigitalOcean droplet 104.248.18.53)

| Service | Port | Notes |
|---|---|---|
| CI.Platform.Gateway | 80 | public entry point |
| Keycloak | 8080 | auth, realm `ci-platform` |
| PostgreSQL | 5432 | databases: ci_platform, ci_keycloak, ci_tenants, ci_users |
| RabbitMQ | 5672 / 15672 | messaging, management UI |
| Valkey (Redis) | 6379 | cache |
| Jaeger | 16686 | distributed tracing |
| Grafana | 3001 | dashboards |
| Prometheus | 9090 | metrics |
| SeaweedFS | 9333/8333/8888 | object storage |
| OpenBao | 8200 | secrets vault |

Deploy: push to `MaciejMajchrzak/CI.Infra` main → GitHub Actions → `docker compose` on droplet.
Keycloak setup (realm, client, test user) runs automatically via `keycloak-setup.sh`.

---

## Key Decisions

| Date | Decision | Reason |
|---|---|---|
| 2026-08-02 | Events crossing service boundaries go in CI.Kernel | Consumers need the type without depending on another service's assembly |
| 2026-08-02 | CI.Platform.Workflow is a dedicated service, not loose consumers | Single observable place for all business processes; services stay decoupled |
| 2026-08-02 | Internal service calls bypass the gateway | Gateway is for external traffic; internal is already trusted on the Docker network |
| 2026-08-02 | KC_HOSTNAME=http://keycloak:8080 | Public IP is unreachable from inside Docker; internal hostname ensures jwks_uri is reachable |
| 2026-08-02 | Keycloak realm ssl_required patched via keycloak-setup.sh on every deploy | Keycloak 25 defaults to EXTERNAL; KC_HOSTNAME_STRICT_HTTPS removed from v2 feature set |
