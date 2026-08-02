# CodingInnovators Platform — Architecture

> Last updated: 2026-08-02

---

## Naming — decided forever

| Concept | Name | Why |
|---|---|---|
| Workspace / namespace | **Tenant** | Party model in the business layer uses "Organization" and "Individual" — tenant is the platform-layer concept above that |
| System operator | **system-admin** | Keycloak role, only CodingInnovators company emails |
| External integration | **Connector** | Industry standard (Kafka Connect, MuleSoft, HubSpot, Zapier) |

---

## Repository Layout

Repo names use dots, matching C# namespace prefixes exactly — zero mental mapping.

```
CI.Kernel                     ← shared contracts NuGet only, everything references this

Platform/
  CI.Platform.Gateway         ← YARP proxy, JWT, tenant-role injection
  CI.Platform.Identity        ← Keycloak adapter, JWT validation, scope middleware
  CI.Platform.Tenants         ← tenant CRUD, module registry, tier config, system-admin endpoints
  CI.Platform.Billing         ← us ↔ tenants: Stripe subscriptions, tier enforcement, usage metering
  CI.Platform.Workflow        ← business process orchestration (see below)
  CI.Platform.DevTools        ← dev bar, API keys, webhook config, event log, event replay

Modules/  (business domains — per-tenant, each has own DB)
  CI.Module.Payments          ← tenants ↔ their customers: Stripe intents, terminal, refunds
  CI.Module.Accounting
  CI.Module.Booking
  CI.Module.Catalog
  CI.Module.HR
  CI.Module.Invoicing
  CI.Module.Legal
  CI.Module.Parties
  CI.Module.Tasks
  CI.Module.Warehouse

Connectors/  (no own DB — consume module events, talk to external APIs)
  CI.Connector.Slack
  CI.Connector.ComarchOptima
  ...

Clients/
  CI.Client.Portal            ← Angular (tenant management portal)
  CI.Client.Mobile            ← Flutter (customer + manage app)
  CI.Client.Public            ← Astro (marketing, public booking entry)

CI.Infra                      ← Docker Compose, Helm, k8s, reusable GitHub Actions
```

---

## Service Pattern (every platform service and module)

```
CI.Platform.<Name>/
  src/
    CI.Platform.<Name>.Domain/         — entities, enums, value objects (no EF, no external deps)
    CI.Platform.<Name>.Core/           — command/query handlers, DTOs, interfaces
    CI.Platform.<Name>.Infrastructure/ — DbContext, migrations, repository implementations
    CI.Platform.<Name>.API/            — controllers, Program.cs, DI wiring
  tests/
    CI.Platform.<Name>.Tests/          — in-memory EF, xUnit, inherits ModuleArchitectureTests
  Dockerfile
  CI.Platform.<Name>.slnx
```

---

## Stack Decisions

| Concern | Choice | Notes |
|---|---|---|
| Runtime | .NET 10 | Not 9 |
| API style | Minimal APIs + controllers | |
| DB | PostgreSQL + PostGIS | Free, geo support, JSON columns |
| ORM | EF Core + Npgsql | |
| Messaging | MassTransit → RabbitMQ (start) | Kafka later if needed (see Transport section) |
| Auth | Keycloak | Two roles: `system-admin`, `tenant-user` |
| Cache | IMemoryCache (L1) + Valkey/Redis (L2) | L1 invalidated via Redis pub/sub across pods |
| Object storage | SeaweedFS (dev) / MinIO-compatible | S3-compatible |
| Secrets | OpenBao (Vault-compatible) | All connection strings pulled at boot |
| Observability | OpenTelemetry → Grafana + Jaeger | Trace every command across modules |
| API docs | Scalar | Replaces Swagger |
| i18n | Keys from day 1 | Zero hardcoded user-facing strings anywhere in code |

---

## Handler Pattern — one handler, five trigger types

This is the core architectural decision. Business logic never knows how it was called.

```
HTTP Controller   ──┐
RabbitMQ Consumer ──┤
Webhook Receiver  ──┼──► Command ──► CommandHandler ──► Result + Event
Workflow Engine   ──┤
Scheduler         ──┘
```

Every write operation is an `ICommand<TResult>`. The entry point (controller, consumer,
webhook handler, workflow step, scheduler job) just wraps the input into a command and
dispatches it via `ICommandBus`. The handler is identical regardless of trigger.

**Rule:** If it changes state → `ICommand` → handler publishes an event.
If it only reads → `IQuery` → synchronous, returns data, no event, never queued.

---

## Transport Abstraction

MassTransit is already the abstraction layer — swapping transports is one line in Program.cs.
Business code (handlers, consumers, publishers) changes zero lines.

```csharp
// In CI.Kernel — all business code uses these
public interface IEventBus  { Task PublishAsync<T>(T evt, CancellationToken ct = default) where T : IEvent; }
public interface ICommandBus { Task<Result> SendAsync<T>(T cmd, CancellationToken ct = default) where T : ICommand; }
public interface IQueryBus  { Task<Result<T>> QueryAsync<T>(IQuery<T> query, CancellationToken ct = default); }

// Kafka-only — opt-in, for replay
public interface IEventLog  { IAsyncEnumerable<T> ReplayAsync<T>(DateTimeOffset from) where T : IEvent; }
```

Transport packages (DI registration only):
- `CI.Kernel.RabbitMQ` — MassTransit + RabbitMQ (start here)
- `CI.Kernel.Kafka` — MassTransit + Kafka + IEventLog (add when replay needed)
- `CI.Kernel.InMemory` — for tests, no infra

**RabbitMQ vs Kafka:** they are NOT the same. RabbitMQ messages are consumed and gone.
Kafka messages stay (configurable retention) and can be replayed from any offset.
Switch to Kafka when: need event replay for new modules, audit log with retention,
or message volume consistently above ~5M/day.

---

## Cross-Service Read Pattern

Queries never go through a queue. Three options for cross-service reads:

| Situation | Approach |
|---|---|
| Workflow reads own module data | MediatR query direct (in-process) |
| Workflow reads another module — simple, needs to be fast | HTTP GET |
| Workflow reads another module — decoupling matters | RabbitMQ request/reply (MassTransit IRequestClient) |
| Frequently-read reference data (tenant config, user roles) | Redis projection |

---

## L1/L2 Cache — Kubernetes Pattern

```
Pod A writes → DB → publishes "cache:invalidate:{key}" to Redis pub/sub
Pod A, B, C, D → all subscribe → each evicts their own L1 IMemoryCache
Next read on any pod → L1 miss → L2 (Redis) hit → or DB if L2 also cold
```

This is the only correct pattern for horizontal scaling with in-memory cache.

---

## Events

**Cross-boundary events** (consumed by another service) → live in `CI.Kernel/Events/`.
**Internal domain events** (consumed within same service) → live in that service's `Domain/Events/`.

Connectors only reference a module's Domain NuGet package — never Core or Infrastructure.
They cannot touch the module's database.

Every command handler **must** publish an event OR carry `[NoEvent("reason")]`.
Architecture test enforces this — the `[NoEvent]` attribute is the explicit opt-out.

---

## Module Manifest

Every module publishes a manifest on startup (to the manifest registry in CI.Platform.Workflow).
The manifest is **auto-generated** from the module's available events, commands, and queries.

```json
{
  "module": "invoicing",
  "version": "1.0.0",
  "events": [
    { "name": "InvoiceCreated", "schema": { "invoiceId": "uuid", "orgId": "uuid", "total": "decimal" } },
    { "name": "InvoiceOverdue", "schema": { "invoiceId": "uuid", "daysPastDue": "int" } }
  ],
  "commands": [
    { "name": "CreateInvoice", "schema": { "..." : "..." } },
    { "name": "SendToKSeF",   "schema": { "..." : "..." } }
  ],
  "queries": [
    { "name": "GetInvoice", "input": { "invoiceId": "uuid" }, "output": { "total": "decimal", "status": "string" } }
  ],
  "triggers": [
    { "name": "OnInvoiceDueSoon", "description": "Fires N days before due date" }
  ]
}
```

Workflow designer reads all manifests → shows available nodes.
Module starts → its nodes appear. Module stops → they grey out. No errors everywhere.

---

## CI.Platform.Workflow

A **dedicated orchestration service** — not loose MassTransit consumers scattered across services.

**What it does:**
- Stores workflow definitions (directed graphs: nodes + edges + trigger)
- Tracks workflow instances and their current state
- Executes steps, waits for conditions (events, timers, human approval)
- Provides API + UI to inspect live status (green tick / red X / spinning per node)
- Retries failed steps, handles timeouts
- Hosts the manifest registry — knows what events/commands/queries every module exposes

**Monetization:**
- N system workflows included in subscription (pre-built, country-aware, read-only but duplicatable)
- Users can create their own workflows up to their tier limit
- Buy more packs for additional user workflow slots

**Workflow testing:** users can run a dry-run / test mode before activating a workflow.

**Example — country-aware invoice flow:**
```
[Trigger: InvoiceCreated]
  → [Validate VAT number]
  → [AI: Detect country rules]
  → [Branch: country]
       PL → [Send to KSeF] → [Generate JPK]
       FR → [Send to Chorus Pro]
       DE → [Send to Elster]
  → [Archive to cold storage]
  → [Notify: Email to client]
```

Polish users see the KSeF branch light up. German users see Elster. All in the same graph.

---

## CI.Platform.DevTools

**Not a dashboard page** — a collapsible dev bar at the bottom of the UI.
Users with dev mode enabled can open it from any screen and see what the current
tenant is doing in the background across all services.

Contents:
- Last N API calls: endpoint, status code, latency
- Events fired with payload
- Workflow runs triggered
- Active workflow graph with live node status

Dedicated pages:
- **API Keys** — public/secret pairs per tenant, scoped, revocable
- **Webhooks** — register URL, select events, view delivery log + retry
- **Event log** — every event with payload, filterable, replayable
- **Workflow runs** — graph with live status

---

## System-Admin

`system-admin` is a Keycloak role — only CodingInnovators company users.

**Never impersonates.** Always uses access-request flow:
1. System-admin requests access to a tenant → `POST /admin/access-requests` in CI.Platform.Tenants
2. Tenant owner approves (or auto-approved for critical support)
3. Time-limited access granted (configurable hours)
4. Full audit trail of what was done during access window

System-admin sees: all tenants, all logs, DB metrics, pod health, cost.
Can request access to any tenant for support — cannot silently enter.

---

## Module vs Connector distinction

| | Module | Connector |
|---|---|---|
| Own DB | Yes | No |
| Emits domain events | Yes | Rarely |
| Has business logic | Yes | No — thin adapter only |
| References | CI.Kernel | CI.Kernel + target Module's **Domain NuGet only** |
| Example | Invoicing, Booking, HR | Slack, ComarchOptima, KSeF, Allegro |

A connector consumes events from modules and talks to an external API — or ingests from
external APIs back into a module via commands. It never touches another module's database.

---

## Architecture Rules (enforced by CI.Kernel.ArchTests)

| Rule | Catches |
|---|---|
| Domain → no Core/Infra/API | Service logic in Domain |
| Core → no Infra/API | DB queries from service layer directly |
| Controllers → no DbContext | Bypassing service layer |
| Events end with `Event` | `UserLoggedIn` without suffix |
| Commands end with `Command` | Inconsistent naming |
| Handlers are sealed | Inheritance on handlers |
| Services are sealed | Inheritance on services |
| Domain → no other modules | Direct module coupling |
| Controllers have `[Authorize]` or `[AllowAnonymous]` | Accidentally public endpoint |
| Controllers have `[RequireModule]` or `[AllowWithoutModule]` | Module endpoint reachable without enabling module |
| AdminControllers have `[RequireSystemAdmin]` | Unprotected admin endpoint |
| Command handlers inject IEventBus OR carry `[NoEvent]` | Write without publishing event |
| Cross-boundary events live in CI.Kernel | Event defined only in module domain |

---

## GitHub Actions — Reusable Workflows (in CI.Infra)

Two reusable workflows, called from every repo:

```yaml
# For API services: build → test → Docker image → GHCR → deploy to droplet
uses: MaciejMajchrzak/CI.Infra/.github/workflows/claude-service.yml@main

# For NuGet packages: build → test → pack → push to GitHub Packages
uses: MaciejMajchrzak/CI.Infra/.github/workflows/claude-nuget.yml@main
```

Every repo has a single `.github/workflows/claude.yml` that calls the appropriate reusable workflow.

---

## Build Order

```
1. CI.Kernel          → contracts NuGet — everything else depends on this
2. CI.Infra           → Docker Compose + reusable GH Actions
3. CI.Platform.Tenants → first real service, validates the full stack pattern
4. CI.Platform.Users
5. CI.Platform.Gateway
6. CI.Platform.Workflow (manifest registry first, executor second, graph editor third)
7. CI.Module.Invoicing → first business module, proves module pattern
8. Everything else in parallel
```

---

## Live Infrastructure (DigitalOcean droplet 104.248.18.53)

| Service | Port | Notes |
|---|---|---|
| CI.Platform.Gateway | 80 | public entry point |
| Keycloak | 8080 | realm `ci-platform`, client `ci-platform-web` |
| PostgreSQL | 5432 | ci_platform, ci_keycloak, ci_tenants, ci_users |
| RabbitMQ | 5672 / 15672 | messaging + management UI |
| Valkey | 6379 | Redis-compatible cache |
| Jaeger | 16686 | distributed tracing |
| Grafana | 3001 | dashboards |
| Prometheus | 9090 | metrics |
| SeaweedFS | 9333 / 8333 / 8888 | object storage (master / volume / filer) |
| OpenBao | 8200 | secrets vault |

Deploy: push to `CI.Infra` main → GitHub Actions → `docker compose` on droplet.
`keycloak-setup.sh` runs on every deploy — idempotent, creates realm + client + test user.
Test credentials: `test / test` on `ci-platform` realm.

---

## Concurrency — ETag, RowVersion, Distributed Lock

Three complementary layers — all must be present, each catches what the others miss.

```
Layer 1 — Redis distributed lock        pessimistic, workflow/job level
  Prevents two workflow instances from starting on the same record at all.
  Key convention: lock:{module}:{entity-type}:{id}

Layer 2 — PostgreSQL xmin (RowVersion)  optimistic, DB level
  BaseEntity.RowVersion maps to the PostgreSQL xmin system column.
  Configured via UseXminAsConcurrencyToken() in every DbContext.
  No extra column — Postgres increments xmin on every row update automatically.
  DbUpdateConcurrencyException → Result.Failure(ErrorCodes.RECORD_LOCKED)

Layer 3 — ETag                          HTTP level, caching + UI conflict detection
  ETag = xmin formatted as 8-digit lowercase hex in quotes: "0000001a"
  GET response  → ETag: "0000001a"
  GET request   → If-None-Match: "0000001a" → 304 Not Modified (no body sent)
  PUT request   → If-Match: "0000001a" → 412 Precondition Failed if stale
```

**CI.Kernel packages (v1.1.0):**
- `CI.Kernel` — `IETaggable`, `ETagHelper`, `IDistributedLock`, `[NoEvent]`, `ErrorCodes.RECORD_LOCKED`
- `CI.Kernel.Http` — `HttpContextETagExtensions`: `IsNotModified()`, `IfMatchPasses()`, `ParseIfMatch()`
- `CI.Kernel.InMemory` — `NullDistributedLock` (tests + local dev)
- `CI.Kernel.Redis` — `RedisDistributedLock` (SETNX + Lua atomic release), `RedisCacheService`, `AddRedisKernel()`

**Usage pattern in every controller:**
```csharp
// GET
if (HttpContext.IsNotModified(entity.RowVersion)) return StatusCode(304);
return Ok(entity);

// PUT
if (!HttpContext.IfMatchPasses(entity.RowVersion)) return StatusCode(412);
```

**Usage in workflow steps:**
```csharp
await using var handle = await _lock.TryAcquireAsync(
    $"lock:invoicing:invoice:{id}", TimeSpan.FromMinutes(5));
if (handle is null) return Result.Failure(ErrorCodes.RECORD_LOCKED);
```

**Architecture tests (in CI.Kernel.ArchTests):**
- `Command_handlers_must_inject_IEventBus_or_carry_NoEvent`
- `Domain_entities_must_extend_BaseEntity`

---

## Party Module — CI.Module.Parties

### Core model

```
Party (base — shared columns: Id, TenantId, RowVersion, Addresses, Contacts, Identifiers, BankAccounts)
  ├─ Organization
  │    LegalName, TradeName?, LegalFormId, CountryCode
  └─ Individual
       FirstName, LastName, DateOfBirth?, CountryCode

PartyIdentifier[]    — NIP, PESEL, VAT-EU, KRS, REGON, passport… (TypeCode + Value)
PartyAddress[]       — registered office, mailing, delivery… (TypeCode + full address)
PartyContact[]       — email, phone, website, LinkedIn (Type + Value + IsPrimary)
PartyBankAccount[]   — IBAN, BIC, BankName
```

### Roles vs Relationships — two separate tables

**PartyRole** — what role this party plays in YOUR business context:

| RoleType | Meaning |
|---|---|
| `Client` | They buy from you — you issue invoices TO them, you earn |
| `Contractor` | They work for you — they invoice YOU, you pay them for services |
| `Supplier` | They supply goods to you — they invoice YOU, you pay them for goods |
| `OwnEntity` | One of YOUR own legal entities (invoice issuer, employer in HR) |
| `Partner` | Business partner — bidirectional commercial relationship |

A party can hold multiple roles simultaneously — a law firm can be your Client AND your Contractor. Two rows in PartyRole, same PartyId.

**PartyRelationship** — structural links between parties (ownership, governance):

| Type | Example |
|---|---|
| `IsShareholderOf` | Individual X owns 30% of Organization Y — has `SharePercent` |
| `IsDirectorOf` | Individual X is board director of Organization Y |
| `IsSubsidiaryOf` | Organization X is a subsidiary of Organization Y |
| `IsMemberOf` | Individual X is a member of Organization Y |
| `IsAgentOf` | Individual X acts as legal agent for Organization Y |

### OwnEntity

A tenant can have multiple own entities (e.g. holding company + operating subsidiary).
`OwnEntity` role on a Party = that party is a legal issuer for invoices, employer in HR, etc.

### Module isolation rule for Parties

**Other modules never import CI.Module.Parties code or query its DB.**
They store `PartyId: Guid` as a foreign reference only. When they need party data:

| Need | Approach |
|---|---|
| Legal document (invoice PDF) | Snapshot party name/address at creation time — never changes retroactively |
| UI display | HTTP GET `/parties/{id}` at render time |
| Frequent reads | Subscribe to `PartyUpdatedEvent` → maintain local read projection |

---

## CI.Platform.Workflow — Pipeline Execution Model

### Instance model

```
WorkflowDefinition
  Graph of nodes + edges, trigger, compensation map, version

WorkflowInstance
  Status: Pending | Running | Paused | Completed | Failed | Cancelled
  StartedAt, CompletedAt, TotalDurationMs
  CurrentNodeId, TriggerPayload

WorkflowStepExecution  (one row per node execution)
  NodeId, NodeName
  Status: Waiting | Running | Success | Warning | Failed | Compensated
  StartedAt, CompletedAt, DurationMs
  RetryCount, MaxRetries
  InputPayload, OutputPayload   — for debugging/audit
  ErrorMessage?

CompensationLog  — rollback audit trail
  StepId, CompensationAction, ExecutedAt, Result
```

### Retry, cancellation, rollback

- **Retries** — configurable per node (count + backoff strategy). RetryCount tracked per step.
- **Cancellation** — `CancelInstance` command transitions instance to `Cancelled`. Running steps finish their current unit of work then stop cleanly.
- **Rollback (saga compensation)** — each step that mutates state registers a compensation action. On failure the engine runs compensations in reverse order. `CompensationLog` records what was undone.

### Real-time UI updates — SignalR

Workflow engine writes step status → publishes `WorkflowStepStatusChanged` event → SignalR hub pushes to connected clients.

Users see the same pipeline visualization as GitHub Actions / Azure DevOps:
- Green tick (Success), Red X (Failed), Yellow triangle (Warning), Spinner (Running)
- Duration per step, total duration
- Retry count badge
- Expandable input/output payload per step
- Cancel button while running

SignalR hub lives in `CI.Platform.Workflow`. The same hub connection is reused for all live-push features (notifications, booking updates, etc.).

---

## Key Decisions Log

| Date | Decision | Reason |
|---|---|---|
| 2026-08-02 | Use `tenant` as the top-level naming (not workspace/namespace/org) | "org" conflicts with Party model which already uses Organization |
| 2026-08-02 | Repo names use dots matching C# namespaces (CI.Kernel, not ci-kernel) | Zero mental mapping between repo and namespace |
| 2026-08-02 | One handler, five trigger types — HTTP/RabbitMQ/Webhook/Workflow/Scheduler all dispatch same ICommand | Business logic never knows how it was called; one place to add/test logic |
| 2026-08-02 | Module manifest auto-generated from available events/commands/queries | Workflow designer gains nodes automatically; no manual registration |
| 2026-08-02 | CI.Platform.Workflow is a dedicated service, not loose consumers | Single observable place for all business processes; services stay decoupled |
| 2026-08-02 | Connectors reference only Domain NuGet of a module, never Core/Infra | Connectors cannot touch module DB; events are the only coupling |
| 2026-08-02 | system-admin never impersonates — always uses access-request flow | Security audit trail; tenant owner stays in control |
| 2026-08-02 | DevTools is a drawer/dev bar at the bottom of the UI, not a separate page | Visible on any screen; shows tenant-wide background activity not just current page |
| 2026-08-02 | Cross-boundary events go in CI.Kernel; internal events stay in Domain | Cross-service consumers need the type without depending on another service's assembly |
| 2026-08-02 | Start with RabbitMQ, add Kafka later — IEventBus abstraction makes this one config line | RabbitMQ handles everything for the first year; Kafka adds replay when needed |
| 2026-08-02 | L1 (IMemoryCache) + L2 (Valkey) cache with Redis pub/sub invalidation | Only correct pattern for K8s horizontal scaling with in-memory cache |
| 2026-08-02 | KC_HOSTNAME=http://keycloak:8080 | Public IP unreachable from inside Docker; internal hostname ensures jwks_uri is reachable |
| 2026-08-02 | Keycloak realm ssl_required patched via keycloak-setup.sh on every deploy | Keycloak 25 defaults EXTERNAL; KC_HOSTNAME_STRICT_HTTPS removed in hostname:v2 |
| 2026-08-02 | Internal service-to-service calls bypass the gateway | Gateway is for external traffic; internal calls are trusted on the Docker network |
| 2026-08-02 | RowVersion = PostgreSQL xmin (uint), not byte[] SQL Server rowversion | No extra column, Postgres manages it automatically, maps via UseXminAsConcurrencyToken() |
| 2026-08-02 | ETag = xmin as 8-digit hex in quotes — three-layer concurrency (Redis lock + xmin + ETag) | Each layer catches what the others miss: Redis=parallel jobs, xmin=DB race, ETag=browser tabs |
| 2026-08-02 | Party splits into Organization and Individual tables | Organization and Individual are correct domain terms; Tenant is the platform-layer concept — no conflict |
| 2026-08-02 | PartyRole (Client/Contractor/Supplier/OwnEntity/Partner) and PartyRelationship (shareholder/director/subsidiary) are separate tables | Roles = business context; Relationships = structural ownership/governance — different concerns |
| 2026-08-02 | Contractor ≠ Client — Client pays YOU, Contractor is paid BY YOU | Same party can hold both roles simultaneously — two rows in PartyRole |
| 2026-08-02 | Other modules store PartyId: Guid only — never import Parties code or DB | Module isolation; legal documents snapshot party data at creation; display reads via HTTP |
| 2026-08-02 | Workflow steps tracked individually — status, duration, retries, input/output, compensation | Pipeline visualization like GitHub Actions; SignalR pushes step status changes in real time |
