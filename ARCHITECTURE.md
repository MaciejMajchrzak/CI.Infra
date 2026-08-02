# CodingInnovators Platform — Architecture

> Last updated: 2026-08-03 (session 3)

---

## Naming — decided forever

| Concept | Name | Why |
|---|---|---|
| Workspace / namespace | **Tenant** | Party model uses "Organization" and "Individual" — tenant is the platform layer above that |
| System operator | **system-admin** | Keycloak role, only CodingInnovators company emails |
| External integration | **Connector** | Industry standard (Kafka Connect, MuleSoft, HubSpot, Zapier) |

---

## Repository Layout

Repo names use dots, matching C# namespace prefixes exactly — zero mental mapping.

```
CI.Kernel                       ← shared contracts NuGet only, everything references this

Platform/
  CI.Platform.Gateway           ← YARP proxy, JWT, tenant-role injection
  CI.Platform.Identity          ← Keycloak adapter, JWT validation, scope middleware
  CI.Platform.Tenants           ← tenant CRUD, module registry, tier config, system-admin endpoints
  CI.Platform.Billing           ← us ↔ tenants: Stripe subscriptions, tier enforcement, usage metering
  CI.Platform.Workflow          ← business process orchestration (see below)
  CI.Platform.DevTools          ← dev bar, API keys, webhook config, event log, event replay
  CI.Platform.CountryConfig     ← country law matrix — taxes, legal forms, identifiers (see below)
  CI.Platform.Notifications     ← delivery: SMTP, SMS, push — all modules publish send commands, this delivers
  CI.Platform.Documents         ← PDF generation + email/document template rendering (used by Invoicing, Booking, Legal)
  CI.Platform.Search            ← OpenSearch abstraction, index management (see below)
  CI.Platform.PublicDiscovery   ← aggregated read-only DB for public booking search (see below)

Modules/  (business domains — per-tenant, each has own DB)
  CI.Module.Parties             ← Organization, Individual, Branch, roles, relationships
  CI.Module.Invoicing           ← invoices, credit notes, numbering series
  CI.Module.Legal               ← contracts, signatures, compliance tasks
  CI.Module.Payments            ← Stripe / Stripe Connect / Tap to Pay
  CI.Module.Booking             ← services, resources, appointments, bundles, subscriptions
  CI.Module.Catalog             ← goods, products, services catalog (different entity types)
  CI.Module.Warehouse           ← stock, movements, reservations
  CI.Module.HR                  ← employees, payroll (contracts live in Legal)
  CI.Module.Tasks               ← work tasks, projects, backlog, time logs
  CI.Module.Accounting          ← chart of accounts, double-entry ledger, KPiR, bank reconciliation, fixed assets, depreciation
  CI.Module.Marketing           ← loyalty points, promo codes, gift vouchers, campaigns, staff commissions

Connectors/  (no own DB — consume module events, talk to external APIs)
  CI.Connector.Slack
  CI.Connector.ComarchOptima
  CI.Connector.KSeF             ← PL mandatory e-invoicing (KSeF government API)
  CI.Connector.OpenBanking      ← bank feed / statement import (adapters per bank/provider)
  ...

CI.Infra                        ← Docker Compose, Helm, k8s, reusable GitHub Actions
```

**Clients (removed from scope):** Portal (Angular), Mobile (Flutter), Public (Astro) — not built.

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
| DB | PostgreSQL + PostGIS | Free, geo support |
| ORM | EF Core + Npgsql | |
| Search | OpenSearch | Geo + full-text (see CI.Platform.Search) |
| Messaging | MassTransit → RabbitMQ (start) | Kafka later if needed |
| Auth | Keycloak | Two roles: `system-admin`, `tenant-user` |
| Cache | IMemoryCache (L1) + Valkey/Redis (L2) | L1 invalidated via Redis pub/sub |
| Object storage | SeaweedFS (dev) / MinIO-compatible | S3-compatible |
| Secrets | OpenBao (Vault-compatible) | All connection strings pulled at boot |
| Observability | OpenTelemetry → Grafana + Jaeger | Trace every command across modules |
| API docs | Scalar | Replaces Swagger |
| Real-time push | SignalR (in CI.Platform.Workflow) | Workflow step updates, notifications |
| i18n | Keys from day 1 | Zero hardcoded user-facing strings anywhere |

---

## Handler Pattern — one handler, five trigger types

Business logic never knows how it was called.

```
HTTP Controller        ──┐
RabbitMQ Consumer      ──┤
Webhook Receiver       ──┼──► Command ──► CommandHandler ──► Result + Event
Workflow (any step)    ──┘   ← includes timer steps — there is no separate Scheduler service
```

**Rule:** If it changes state → `ICommand` → handler publishes an event OR carries `[NoEvent("reason")]`.
If it only reads → `IQuery` → synchronous, returns data, no event, never queued.

---

## No JSON in Domain Entities

**Rule: no JSON/JSONB columns on domain entities.** Everything is proper relational tables.

Exceptions where storing serialized text is correct:
- Webhook/event delivery payloads — outbound HTTP body, never queried inside, only replayed
- Workflow step input/output — debug snapshot, read as opaque blob

For everything else: proper child tables or typed EAV (see CountryConfig extended fields).

---

## Transport Abstraction

```csharp
// In CI.Kernel — all business code uses these
public interface IEventBus   { Task PublishAsync<T>(T evt, CancellationToken ct = default) where T : IEvent; }
public interface ICommandBus { Task<Result> SendAsync<T>(T cmd, CancellationToken ct = default) where T : ICommand; }
public interface IQueryBus   { Task<Result<T>> QueryAsync<T>(IQuery<T> query, CancellationToken ct = default); }

// Kafka-only — opt-in, for replay
public interface IEventLog   { IAsyncEnumerable<T> ReplayAsync<T>(DateTimeOffset from) where T : IEvent; }
```

**RabbitMQ vs Kafka:** RabbitMQ messages are consumed and gone. Kafka messages persist and can be replayed.
Switch to Kafka when: need event replay for new modules, audit log with retention, or > ~5M messages/day.

---

## Cross-Service Read Pattern

| Situation | Approach |
|---|---|
| Handler reads own module data | Repository direct |
| Handler reads another module — simple, fast | HTTP GET to that service |
| Handler reads another module — decoupling matters | RabbitMQ request/reply (MassTransit IRequestClient) |
| Frequently-read reference data | Redis projection |

---

## L1/L2 Cache — Kubernetes Pattern

```
Pod A writes → DB → publishes "cache:invalidate:{key}" to Redis pub/sub
All pods (A, B, C, D) subscribe → each evicts own IMemoryCache
Next read on any pod → L1 miss → L2 (Redis) hit → or DB if L2 also cold
```

---

## Events

**Cross-boundary events** (consumed by another service) → live in `CI.Kernel/Events/`.
**Internal domain events** (consumed within same service) → live in that service's `Domain/Events/`.

Connectors only reference a module's Domain NuGet package — never Core or Infrastructure.
They cannot touch the module's database.

Every command handler **must** publish an event OR carry `[NoEvent("reason")]`.
Architecture test enforces this.

---

## Concurrency — ETag, RowVersion, Distributed Lock

```
Layer 1 — Redis distributed lock        pessimistic, workflow/job level
  Key: lock:{module}:{entity-type}:{id}

Layer 2 — PostgreSQL xmin (RowVersion)  optimistic, DB level
  BaseEntity.RowVersion maps to the PostgreSQL xmin system column.
  DbUpdateConcurrencyException → Result.Failure(ErrorCodes.RECORD_LOCKED)

Layer 3 — ETag                          HTTP level, caching + UI conflict detection
  ETag = xmin as 8-digit lowercase hex in quotes: "0000001a"
  GET  → ETag: "0000001a"
  GET  → If-None-Match: "0000001a" → 304 Not Modified
  PUT  → If-Match: "0000001a"      → 412 Precondition Failed if stale
```

**CRITICAL: Child collection update pattern in handlers.**
Never call `entity.Children.Clear()` — causes `DbUpdateConcurrencyException` in EF InMemory.
Always use a repository method that calls `RemoveRange` + `AddRange` on the DbSet directly,
and compute aggregates from the new list (not from the navigation collection):

```csharp
var newLines = cmd.Lines.Select(l => new InvoiceLine { ... }).ToList();
repo.ReplaceLines(entity.Lines.ToList(), newLines);  // RemoveRange + AddRange on DbSet
entity.Total = newLines.Sum(l => l.Amount);          // NOT entity.Lines.Sum()
```

---

## Module Manifest

Every module publishes a manifest on startup to the manifest registry in CI.Platform.Workflow.
The manifest is auto-generated from available events, commands, and queries.

Workflow designer reads all manifests → shows available nodes.
Module starts → its nodes appear. Module stops → they grey out.

---

## CI.Platform.CountryConfig  ← NEW PLATFORM DOMAIN

**Rule: zero Polish-law-specific code anywhere in business modules.**
No hardcoded VAT%, PLN, NIP, REGON, ZUS, or any country-specific constant in domain entities.
All country-specific rules live in CI.Platform.CountryConfig and are referenced by code strings only.

### Entity model — named child tables, no JSON

```
CountryConfig
  ├── LegalForm[]                — code, name, description
  │                                 e.g. PL: JDG, sp. z o.o., SA | DE: GmbH, AG, UG | FR: SARL, SAS
  │
  ├── TaxIdentifierType[]        — code, name, validationPattern, isRequired, appliesTo (Org/Individual/Both)
  │                                 e.g. PL: NIP, REGON, KRS, PESEL | DE: Steuernummer, USt-IdNr
  │
  ├── ConsumptionTaxRate[]       — name, ratePercent, validFrom, validTo, isReduced, status (Past/Current/Planned)
  │                                 jurisdictionLevel? (National/State/County/City), jurisdictionCode? (e.g. "US-CA")
  │                                 temporal — past rates stored for invoice history, planned for forward-dating
  │                                 what countries call it: VAT (EU), GST (AU/NZ/CA/IN), Sales Tax (US), TVA (FR)
  │                                 jurisdictionLevel/Code nullable — EU/PL/GB national-only; US needs per-state
  │
  ├── IncomeTaxScheme[]          — code, name, type (Progressive|Flat|LumpSum|Other)
  │     └── IncomeTaxSchemeRate[]
  │           activityCode?, minIncome?, maxIncome?, ratePercent, description
  │           Progressive: income bracket bands (ThresholdAmount + RatePercent per band)
  │           Flat: single rate entry, no activityCode
  │           LumpSum (ryczałt): one rate per activity/PKD code — e.g. IT=12%, catering=3%, rental=8.5%
  │           A sole trader can operate under TWO LumpSum rates simultaneously (two activities)
  │
  ├── TaxObligation[]            — code, name, type (Income/Social/Health/VAT/Customs/Other), description
  │     └── TaxObligationComponent[]
  │           name, ratePercent, validFrom, validTo, paidBy (Employee/Employer/Both), isMandatory, description
  │           e.g. ZUS: emerytura, renta, wypadkowe, chorobowe, zdrowotne, FP, FGŚP — each is one component
  │
  ├── TaxDeductionCategory[]     — code, name, description, maxAmount?, validFrom, validTo
  │                                 e.g. PL: koszty uzyskania przychodu, ulga na dzieci
  │
  ├── AddressFormat[]            — fieldName, label, isRequired, sortOrder
  │                                 drives address entry forms per country
  │
  ├── EntityFieldDefinition[]    — entityType (Invoice/Party/Contract/...), fieldKey, label,
  │                                 dataType (String/Decimal/Date/Boolean), isRequired, validationPattern
  │                                 drives country-specific fields on entities via typed EAV
  │
  ├── CountryFilingCapability[]  — filingType (JPK_V7/SAF-T/MTD/1099/...), isMandatory, mandatoryFrom?, description
  │                                 which tax export formats this country requires → drives which connectors to activate
  │
  └── CountryEInvoiceCapability[]— systemName (KSeF/FatturaPA/MakingTaxDigital/...), isMandatory, mandatoryFrom?
                                     whether structured e-invoicing is mandatory and from when
```

### Country Plugin — computation that cannot be generic

Rates and legal forms are **data** (CountryConfig). Calculation logic and filing formats are **code** (ICountryPlugin).

```csharp
// In CI.Kernel — all modules can reference this interface
public interface ICountryPlugin
{
    string CountryCode { get; }
    Task<IReadOnlyList<TaxObligationAmount>> CalculateMonthlyObligationsAsync(TenantContext ctx, YearMonth period, CancellationToken ct);
    Task SubmitEInvoiceAsync(Invoice invoice, CancellationToken ct);
    Task<FilingExport> ExportFilingAsync(string filingType, DateRange period, CancellationToken ct);
}
```

Implementations: `PolandCountryPlugin`, `GermanyCountryPlugin`, `UKCountryPlugin`, etc.
Registered in DI as `IEnumerable<ICountryPlugin>`, resolved by `CountryCode` at call time.
**Adding a new country = seed CountryConfig rows + write one country plugin class.**
Generic code never references specific countries — only `CountryCode` strings.

### Country-specific entity fields — typed EAV (no JSON)

Domain entities (Invoice, Party, Contract) do NOT have country-specific typed properties.
Instead each module has an `ExtendedField` child table:

```
InvoiceExtendedField  (InvoiceId, TenantId, CountryCode, FieldKey, StringValue, DecimalValue, DateValue, BoolValue)
PartyExtendedField    (PartyId,   TenantId, CountryCode, FieldKey, ...)
ContractExtendedField (ContractId, TenantId, CountryCode, FieldKey, ...)
```

`FieldKey` matches `EntityFieldDefinition.fieldKey` in CountryConfig.
UI reads the definitions → builds the form dynamically → stores typed values in the EAV table.
Queryable, no JSON, schema-driven, country-agnostic at the entity level.

### What this means for specific fields

- **SKU** — NOT a typed property on catalog items or invoice lines.
  Goes in `CatalogItemExtendedField` / `InvoiceLineExtendedField` with key `"sku"` if the country/business needs it.
- **VAT rate** — stored as `VatRateCode` (string FK to CountryConfig.VatRate) + `VatRateSnapshot` (decimal % at time of invoice).
  Never a hardcoded `decimal VatPercent` property.
- **NIP/REGON** — stored in `PartyIdentifier[]` (TypeCode + Value), not as typed properties on Organization.
- **KSeF number** — `InvoiceExtendedField` with key `"pl-ksef-number"` for Polish invoices only.

---

## CI.Module.Parties — Organization, Individual, Branch

### Three entity types, no shared base table

Organization and Individual are **separate tables** (not table-per-hierarchy). They share no DB table because they will accumulate different columns over time.

```
Organization
  Id, TenantId, TradeName, CountryCode, LegalFormCode, IsActive, RowVersion
  + Identifiers[], Addresses[], Contacts[], BankAccounts[], ExtendedFields[]

Individual
  Id, TenantId, FirstName, LastName, DateOfBirth?, NationalityCode, IsActive, RowVersion
  + Identifiers[], Addresses[], Contacts[], BankAccounts[], ExtendedFields[]
```

Shared child tables use a polymorphic FK (`OwnerType: Organization|Individual`, `OwnerId: Guid`):
- `PartyIdentifier[]` — TypeCode + Value (NIP, REGON, passport, PESEL…)
- `PartyAddress[]` — TypeCode + full address fields + lat/lng
- `PartyContact[]` — Type (Phone/Email/Instagram/Facebook/TikTok/Website/LinkedIn/Other) + Value — **unbounded list**
- `PartyBankAccount[]` — IBAN, BIC, BankName, TypeCode
- `PartyExtendedField[]` — typed EAV for country-specific fields

### Branch — the bookable/operative unit

A Branch is a direct child of either an Organization or an Individual.
**Branch has its own name** — it is NOT the legal name. One Organization can have branches with completely different trading names.

```
Branch
  Id, TenantId, OwnerType, OwnerId (FK to Org or Individual)
  BranchName          — "Downtown Barber", "Airport Location", "Studio B"
  Description?
  IsActive
  Address             — street, city, postal, country, lat (double), lng (double)  ← PostGIS point too
  OpeningHours[]      — DayOfWeek, OpenTime, CloseTime, IsClosed, ExceptionDate?
  Contact[]           — same unbounded polymorphic list as party contacts
  Image[]             — Url, AltText, SortOrder, IsPrimary
  MaxBookingHorizonDays?
  AutoAcceptBookings  (bool)
  RowVersion
```

Branch is the entity that gets **published to PublicDiscovery** for public search.

### Roles — what role a Party plays in YOUR tenant context

```
PartyRole
  PartyId, OwnerType (Organization|Individual), TenantId
  Role: Client | Contractor | Supplier | OwnEntity | Partner
```

A party can hold multiple roles simultaneously (law firm = Client AND Contractor).

### Relationships — structural ownership/governance links between parties

```
PartyRelationship
  FromId, FromType, ToId, ToType, TenantId
  Type: IsShareholderOf | IsDirectorOf | IsSubsidiaryOf | IsMemberOf | IsAgentOf
  SharePercent? (for IsShareholderOf)
  ValidFrom, ValidTo?
```

### Module isolation rule

Other modules store `OrganizationId: Guid` or `IndividualId: Guid` as foreign references only.
Legal documents snapshot name/address at creation. Display reads via HTTP.

---

## CI.Module.Booking — Full Architecture

### BookingProfile — the entity people actually book with

A Branch can have one BookingProfile. BookingProfile holds booking-specific configuration that doesn't belong on the core Branch entity:

```
BookingProfile
  Id, TenantId, BranchId (FK)
  Currency (3-char, from CountryConfig)
  DefaultBookingMode
  RequiresDeposit (bool), DepositPercent?
  CancellationPolicyHours?    — free cancellation window
  MaxConcurrentBookings?
  RowVersion
```

### Service — what customers book

```
Service
  Id, TenantId, BranchId
  Name, Description?
  Category (ServiceCategoryId?)
  DurationMinutes?            — null if "from-to" style
  DurationFrom?, DurationTo?  — for flexible duration services
  BasePrice, Currency
  IsActive
  RequiresConfirmation (bool)
  AutoAccept (bool)           — overrides branch setting per service
  MaxParticipants (int, default 1)
  MaxDaysAhead?               — overrides branch setting per service
  RowVersion

ServiceVariant[]
  ServiceId, Name, PriceOverride?, DurationOverride?, Description?
  e.g. "Coupe" / "SUV" / "Limo" under "Car Detailing"

ServiceAcceptance[]
  ServiceId, Title, AcceptanceText, IsRequired
  MustSignBefore: Booking | Confirmation
  e.g. "Tattoo consent", "Medical disclaimer"

ServiceCategory
  Id, TenantId, Name, SortOrder, ParentCategoryId?
```

### Resource — who or what performs the service

```
Resource
  Id, TenantId, BranchId
  Name, Type (Staff | Room | Equipment)
  BookingUnit: BySlot | ByHour | ByDay
  BookingMode: FullOnly | ByPersonOnly | Mixed
  Capacity (int)              — max concurrent bookings (persons or sessions)
  IsAvailable (bool)
  EmployeeId?: Guid?          — nullable link to CI.Module.HR Employee (seniority, skills live there)
  RowVersion

ResourceServiceConfig[]       — override per (Resource × Service) combination
  ResourceId, ServiceId
  PriceOverride?, DurationOverride?
  e.g. Senior stylist charges +20% for same haircut service
```

### Booking modes explained

| BookingMode | Rule |
|---|---|
| `FullOnly` | One booking fills the resource regardless of capacity |
| `ByPersonOnly` | Multiple bookings allowed up to `Capacity`, each counts as 1 person |
| `Mixed` | First booking in a slot sets the mode: if Full → blocks all; if ByPerson → others can join up to capacity |

### Concurrent booking scenarios

- **Two people, same room, same time** → Room has `BookingMode=ByPersonOnly`, `Capacity=2`. Two separate appointments, same room, same slot.
- **Manicure + pedicure simultaneously** → Two separate resources (nail_station_1, nail_station_2). No conflict — availability checked independently per resource.
- **Sequential massages** → Two appointments, same resource, consecutive slots.
- **Spa double massage** → Two appointments, same room, same slot, ByPersonOnly capacity=2.

### Appointment

```
Appointment
  Id, TenantId, BranchId
  CustomerId (Guid, refs Parties), CustomerName (snapshot), CustomerEmail (snapshot)
  Status: Draft | AwaitingPayment | AwaitingConfirmation | Confirmed | InProgress | Completed | Cancelled | NoShow | Disputed
  Notes?, CancelReason?
  DepositPaidAt?, PaidAt?, StripePaymentIntentId?
  RowVersion

AppointmentLine[]             — services/variants booked (aggregate child)
  AppointmentId, ServiceId, ServiceVariantId?, ResourceId?
  ServiceNameSnapshot, VariantNameSnapshot
  StartAt, EndAt
  UnitPrice (snapshot), Qty, TotalPrice

AppointmentProduct[]          — goods sold alongside (aggregate child)
  AppointmentId, CatalogItemId, Name (snapshot), Qty, UnitPrice (snapshot)

AppointmentAcceptance[]       — signed consent forms (aggregate child)
  AppointmentId, ServiceAcceptanceId, Title (snapshot), SignedAt, SignerName
```

### Stay — grouping multiple appointments under one visit

A `Stay` links any number of independent `Appointment` records together. Used for hotel stays (room + spa + breakfast), multi-day retreat bookings, or any scenario where a guest makes multiple appointments that should be billed and managed together.

```
Stay
  Id, TenantId, BranchId
  CustomerId (Guid), CustomerName (snapshot), CustomerEmail (snapshot)
  CheckIn (date), CheckOut (date)
  Notes?
  Status: Active | CheckedOut | Cancelled
  RowVersion
```

`Appointment` gets a nullable `StayId: Guid?` FK. A standalone appointment (beauty salon, barber) has `StayId = null`. A hotel room appointment and a spa appointment during the same visit both have the same `StayId`. Payment links to `StayId` (single bill for the whole stay) or to individual `AppointmentId` (pay per service).

### Bundle booking

```
Bundle
  Id, TenantId, BranchId, Name, Description?, TotalPrice, Currency, IsActive

BundleItem[]
  BundleId, ServiceId, ServiceVariantId?, Qty
```

Booking a bundle creates N `AppointmentLine` rows from the bundle definition. Price is snapshotted from the bundle total.

### Subscription / recurring booking

```
BookingSubscription
  Id, TenantId, CustomerId, BranchId
  Status: Active | Paused | Cancelled | Expired
  RecurrenceRule              — iCalendar RRULE string: "FREQ=WEEKLY;BYDAY=MO;COUNT=12"
  ServiceId, ResourceId?, ServiceVariantId?
  StartDate, EndDate?
  MaxInstances?
  NextOccurrenceAt
  RowVersion

SubscriptionAppointment[]     — join table: subscription → generated appointments
  SubscriptionId, AppointmentId
```

Subscription generates appointments ahead (up to `MaxDaysAhead` on the service/branch). Cancelling one instance cancels that `Appointment` only. Cancelling the subscription marks all future instances.

### PublicDiscovery projection

On booking changes, `BranchPublishedEvent` / `BranchUpdatedEvent` / `BranchRemovedEvent` flow to `CI.Platform.PublicDiscovery`. That service maintains a denormalized `PublishedBranch` with embedded service/availability data and an OpenSearch document for geo+text queries.

---

## CI.Module.Payments — Generic Payment Provider Architecture

No provider-specific fields in domain entities. The provider is a plugin — swap Stripe for Mollie, Przelewy24, or Adyen by changing one registration.

```csharp
// In CI.Kernel — all modules can reference this
public interface IPaymentProvider
{
    string ProviderName { get; }  // "stripe" | "mollie" | "przelewy24" | "adyen" | ...
    Task<PaymentResult>    CreatePaymentAsync(PaymentRequest req, CancellationToken ct);
    Task<PaymentResult>    CreateMarketplacePaymentAsync(MarketplacePaymentRequest req, CancellationToken ct);
    Task<PaymentResult>    CreateTerminalPaymentAsync(TerminalPaymentRequest req, CancellationToken ct);
    Task<RefundResult>     RefundAsync(string providerTransactionRef, decimal amount, string reason, CancellationToken ct);
    Task                   HandleWebhookAsync(string payload, string signature, CancellationToken ct);
}
```

Three modes are always available regardless of provider (Standard, Marketplace, InPerson). Each provider exposes all three — if a provider doesn't support one mode, it throws `NotSupportedException`.

```
PaymentTransaction
  Id, TenantId
  Amount, Currency
  Status: Pending | Processing | Completed | Failed | Refunded | Disputed
  Method: Card | BankTransfer | Cash | Terminal | Voucher | LoyaltyPoints | Other
  Mode: Standard | Marketplace | InPerson
  ProviderName               — "stripe", "mollie", "przelewy24", "adyen", ...
  ProviderTransactionRef     — provider's own ID (PaymentIntent ID, order ID, etc.)
  ProviderAccountRef?        — for Marketplace: sub-account / connected merchant ID
  PlatformFeeAmount?         — platform cut in Marketplace mode
  TransferAmount?            — amount going to the merchant in Marketplace mode
  LinkedAppointmentId?
  LinkedStayId?              — for hotel-style: link to Stay instead of one appointment
  LinkedInvoiceId?
  FailureReason?
  RowVersion

Refund[]                     — aggregate child
  PaymentTransactionId
  Amount, Reason
  Status: Pending | Approved | Rejected
  ProviderRefundRef?         — provider's own refund ID
```

---

## CI.Platform.Workflow — Redesign

### Instance model

```
WorkflowDefinition
  Graph of nodes + edges, trigger, compensation map, version

WorkflowInstance
  Status: Pending | Running | Paused | Completed | Failed | Cancelling | Cancelled | Compensating | Compensated
  StartedAt, CompletedAt, TotalDurationMs
  TimeoutAt?
  CancelledAt?, CancelReason?
  CurrentNodeId, TriggerPayload (text — not queried, only replayed)

WorkflowStepExecution         — one row per node execution
  NodeId, NodeName
  Status: Waiting | Running | Succeeded | Warning | Failed | Skipped | TimedOut | Compensated
  StartedAt, CompletedAt, DurationMs
  TimeoutAt?
  RetryCount, MaxRetries, NextRetryAt?
  WarningMessage?
  InputPayload (text), OutputPayload (text)   — debug snapshot, opaque blob
  ErrorMessage?
  CompensationStepId?         — FK to the step that compensates this one

WorkflowSignal                — human approval / external resume
  InstanceId, NodeId
  ExpectedSignalKey
  ReceivedAt?, ReceivedBy?
  Status: Waiting | Received | TimedOut

CompensationLog               — rollback audit trail
  InstanceId, StepId, CompensationAction, ExecutedAt, Result
```

### Operations

- **Cancel** → `Cancelling`, running steps finish current unit then stop, then `Cancelled`
- **Rerun whole** → new Instance from same Definition, preserves original TriggerPayload
- **Rerun step** → only on Failed steps; resets that StepExecution, re-executes from that node
- **Rollback (saga)** → walks backwards through `Succeeded` steps, runs each `CompensationStep` in reverse order, records in `CompensationLog`

### Node types — parallel execution and fire-and-forget

```
WorkflowNode.Type:
  Task          — call a handler, HTTP endpoint, or publish an event
  Condition     — if/else branch based on step output
  Timer         — WaitUntil(datetime) or WaitFor(duration)
  Signal        — wait for external input: human approval or webhook callback
  ParallelFork  — split into N concurrent branches, each runs independently
  ParallelJoin  — wait for branches before continuing; WaitFor: All | Any | N-of-M
```

```
WorkflowNode (additional fields)
  IsFireAndForget (bool)  — failure → Warning status; workflow continues regardless
  ContinueOnWarning (bool)— ParallelJoin does not block on fire-and-forget branches
```

How it works — like GitHub Actions jobs:
```
  Task: charge payment
    → ParallelFork (3 branches)
        Branch A: send email      IsFireAndForget=true  ← failure = Warning, never blocks
        Branch B: send SMS        IsFireAndForget=true
        Branch C: update PublicDiscovery
    → ParallelJoin (WaitFor=All, skips fire-and-forget branches)
  → Task: mark appointment Confirmed
```

Fan-in with partial wait — `ParallelJoin(WaitFor=Any)` continues as soon as the first branch completes; `WaitFor=N` requires N of M. Useful for: "wait for payment confirmation OR manual override signal, whichever comes first."

### Timer steps — no separate Scheduler service

Time-based triggers are Workflow steps. There is no `CI.Platform.Scheduler`.

Supported timer step types:
- **WaitUntil(datetime)** — pause instance until an absolute moment (e.g. `appointment.StartAt − 24h`)
- **WaitFor(duration)** — pause for a relative duration (e.g. 90 days to detect lapsed clients)

```
WorkflowTimer                 — one row per waiting timer step
  InstanceId, StepId
  FireAt (datetime, indexed)
  Status: Waiting | Fired | Cancelled
```

A background poller queries `WHERE FireAt <= now AND Status = Waiting`, fires each due timer, and resumes the workflow instance from that step. Persists across service restarts — no in-memory timers, no cron.

Examples of what this replaces a separate scheduler with:
- Appointment reminder → `AppointmentConfirmed` starts workflow → `WaitUntil(StartAt − 24h)` → send notification
- Lapsed client → `AppointmentCompleted` starts workflow → `WaitFor(90 days)` → check if rebooked → if not, send campaign
- Birthday voucher → `CustomerCreated` starts workflow → `WaitUntil(nextBirthday − 7 days)` → send voucher

### Real-time UI — SignalR

`WorkflowStepStatusChanged` event → SignalR hub → client receives live node updates.
Same SignalR connection reused for notifications, booking updates.

---

## CI.Platform.DevTools — Stripe-style Developer Mode

Not a separate page — a collapsible drawer at the bottom of any screen.
Visible only when the tenant has dev mode enabled.

### Drawer content (live feed)
- Last N API calls: method, path, status code, latency
- Events fired: name, payload
- Workflow runs triggered
- Active webhook deliveries

### Dedicated pages
- **API Keys** — public/secret key pair, scoped (`invoicing:read`, `booking:write`, etc.), revocable
- **Webhooks** — register URL, choose event types, HMAC signing secret (private key shown once only), delivery log with response body + retry button
- **Event log** — every domain event, filterable by type/time, replayable to any webhook endpoint
- **Workflow runs** — graph with live step status (same visualization as workflow engine)

### Entity model

```
WebhookEndpoint
  Id, TenantId, Name, Url, SigningSecretHash, SigningSecretPrefix (first 8 chars, shown in UI)
  EventTypeFilter[]   — which event types to deliver
  IsActive, RowVersion

WebhookDelivery       — append-only
  EndpointId, TenantId, EventType
  Payload (text — outbound HTTP body, replayed as-is, not queried inside)
  Status: Sent | Failed | Retrying
  AttemptedAt, ResponseCode?, ResponseBodyPreview?, DurationMs?, FailureReason?
  RetryCount

ApiEventLog           — append-only, powers the dev bar feed
  TenantId, ActorId, Method, Path, StatusCode, DurationMs
  RequestBodyPreview?, ResponseBodyPreview?
  OccurredAt

FeatureFlag
  Id, TenantId, Name, Key (unique per tenant), IsEnabled, Description?

ApiKey
  Id, TenantId, Name, KeyHash, KeyPrefix (first 8), Scopes, ExpiresAt?, IsRevoked
```

---

## CI.Platform.Search — OpenSearch Abstraction

One shared service owns all OpenSearch index definitions and the `ISearchIndexer<T>` abstraction.
Modules push to their index on write events; consumers query via the search service HTTP API.

### Indexes

| Index | Primary use | Geo? |
|---|---|---|
| `branches` | Public discovery — find nearby bookable places | ✅ lat/lng |
| `services` | Search services within a branch/area | ✅ inherited |
| `parties` | CRM search — clients, contractors | ❌ |
| `tasks` | Task search within tenant | ❌ |
| `invoices` | Invoice search, buyer name, number | ❌ |
| `catalog` | Product/service catalog search | ❌ |

### Rule
- Modules publish domain events → CI.Platform.Search consumes → updates index
- Deletes propagate: `BranchDeletedEvent` → remove from `branches` index
- Search service never reads module DBs directly

---

## CI.Platform.PublicDiscovery — Aggregated Public Search DB

Separate service with its own DB. Serves unauthenticated public consumers (booking search widget, public site).

No per-tenant data is ever queried directly for public reads — only PublicDiscovery data.

```
PublishedBranch
  Denormalized: BranchName, Address, lat/lng, OpeningHours, Images,
                IsAvailableToday, AverageRating, ReviewCount
  Embedded services list (top N active services)

PublishedService
  BranchId, Name, DurationMinutes, BasePrice, Currency, CategoryName

PublishedAvailability
  BranchId, ServiceId, Date, AvailableSlots (int)
  Recomputed by AvailabilityWorker (background job)
```

Publish flow: `BranchPublishedEvent` → `PublicDiscoveryConsumer` → upsert `PublishedBranch` + push to OpenSearch `branches` index.
Delete flow: `BranchRemovedEvent` → delete from PublishedBranch + remove from OpenSearch.

### Availability — event-driven primary, scheduled reconciliation

`PublishedAvailability` is **not** maintained only by a background worker. Every booking change updates it immediately via dedicated event consumers:

| Event | Consumer action |
|---|---|
| `BookingCreatedEvent` | Decrement available slots for that service + date |
| `BookingCancelledEvent` | Increment available slots |
| `BookingCompletedEvent` | Mark slot as used (historical) |
| `ServiceUpdatedEvent` | Recalculate affected date range |
| `ResourceBlockedEvent` | Mark resource unavailable for blocked period |
| `OpeningHoursChangedEvent` | Recalculate affected dates |

`AvailabilityWorker` runs as a **reconciliation job** (nightly or on-demand) to catch any drift from missed events or race conditions. It is NOT the primary update path.

---

## CI.Module.Catalog — Goods vs Products vs Services

Three distinct entity types — different shapes, different inventory rules:

```
Good          — physical item with stock (trackable in Warehouse)
              Name, Sku? (ExtendedField), Weight?, Unit, CurrentStock (from Warehouse events)

Product       — manufactured/packaged item, may or may not track stock
              Name, Brand?, Sku? (ExtendedField), Unit

ServiceItem   — time-based, no stock, links to Booking module
              Name, DefaultDurationMinutes, DefaultPrice
```

**SKU is NOT a typed property** on any of these. It goes in `CatalogItemExtendedField` with key `"sku"` when the tenant's country/workflow requires it. Same for barcode, GTIN, etc.

All three share:
- `CatalogItemExtendedField[]` — typed EAV for country/business-specific attributes
- `PriceHistory[]` — validFrom, validTo, price, currency
- `CategoryId?` — shared `CatalogCategory` tree
- `Image[]`

---

## CI.Platform.Notifications — Real Delivery Layer

Notification *modelling* (when to send, to whom) lives per-module or in Workflow timer steps.
CI.Platform.Notifications is the **delivery service** — receives send commands and dispatches to the right channel.

| Channel | Provider |
|---|---|
| Email (SMTP) | Resend / Mailgun / SES — tenant brings own or uses platform default |
| SMS | Twilio / Vonage |
| Push (FCM/APNs) | Firebase (Android), APNs (iOS) |
| In-app | SignalR hub in CI.Platform.Workflow |

```csharp
// Any module publishes this — Notifications service consumes it
record SendNotificationCommand(
    Guid TenantId,
    string Channel,        // "email" | "sms" | "push" | "in-app"
    string Recipient,      // email address, phone number, device token, or userId
    string TemplateKey,    // maps to a template in CI.Platform.Documents
    object TemplateData,   // key-value bag passed to template renderer
    string? IdempotencyKey // prevents duplicates on retry
) : ICommand;
```

```
NotificationLog               — append-only delivery record
  TenantId, Channel, Recipient, TemplateKey
  Status: Queued | Sent | Failed
  SentAt?, FailureReason?, IdempotencyKey?
```

---

## CI.Platform.Documents — PDF Generation + Template Rendering

Used by: Invoicing (invoice PDFs), Booking (confirmation emails), Legal (contract PDFs), Notifications (email bodies).

- Renders Handlebars templates for email subjects and bodies
- Renders HTML → PDF (headless Chromium) for invoices, contracts, reports
- Tenants can override platform default templates with their own branded versions

```
DocumentTemplate
  Id, TenantId? (null = platform default), Key, Type: Email | PDF | Preview
  SubjectTemplate?    — for email channel only (Handlebars)
  BodyTemplate        — Handlebars string
  LanguageCode        — "pl", "en", "de", etc.
  IsDefault           — true on platform defaults, false on tenant overrides
  RowVersion
```

**Rule:** PDF rendering is async (Workflow step) for documents > 1 page; synchronous for previews and confirmation emails.

---

## CI.Module.Marketing — Loyalty, Campaigns, Vouchers, Commissions

Isolated from Booking because these features will also apply to future Catalog/e-commerce.
Booking, Invoicing, and Catalog push events → Marketing consumes them → awards points, triggers campaigns.

### Entity model

```
// Loyalty
LoyaltyProgram
  Id, TenantId, BranchId?
  PointsPerCurrencyUnit   — e.g. 1.0 = 1 point per 1 PLN
  PointsExpiryDays?
LoyaltyTier[]
  ProgramId, Name, MinPoints, BenefitType (DiscountPercent|FreeService|PriorityBooking|FreeCancel), BenefitValue?
CustomerLoyaltyBalance
  TenantId, CustomerId, ProgramId, Points, LifetimePoints, CurrentTierName
LoyaltyTransaction          — append-only
  CustomerId, ProgramId, PointsDelta, Reason (Earned|Redeemed|Expired|Adjusted)
  LinkedAppointmentId?, LinkedInvoiceId?, OccurredAt

// Gift vouchers
Voucher
  Id, TenantId, Code (unique), Type: GiftCard | ServiceCredit | DiscountPercent | DiscountFixed
  Value, Currency, ExpiresAt?, MaxUses?, UsedCount
  Status: Active | Exhausted | Expired | Revoked
  LinkedCampaignId?
VoucherRedemption           — append-only
  VoucherId, CustomerId, RedeemedAt, AmountUsed, LinkedAppointmentId?, LinkedInvoiceId?

// Promo codes
PromoCode
  Id, TenantId, Code, Type: DiscountPercent | DiscountFixed | FreeService
  Value, ValidFrom, ValidTo?, MaxUses?, UsedCount, MinOrderAmount?
  AppliesTo: All | ServiceCategory | SpecificService, AppliesToId?

// Campaigns (orchestrated by Workflow timer steps)
Campaign
  Id, TenantId, BranchId?
  Type: Birthday | LapsedClient | Manual | LastMinuteDiscount
  Status: Draft | Scheduled | Running | Completed | Cancelled
  TargetSegment: AllCustomers | LoyaltyTier | CustomTag, SegmentValue?
  Channel: Email | SMS | Push
  TemplateKey               — → CI.Platform.Documents
  VoucherId?                — optional reward attached
  ScheduledAt?, ExecutedAt?
CampaignRecipient           — append-only
  CampaignId, CustomerId, Status: Queued | Sent | Failed, SentAt?

// Staff commissions
CommissionRule
  Id, TenantId, ResourceId (Staff type only)
  Type: PercentOfRevenue | FixedPerAppointment, Value
  AppliesTo: All | SpecificService, AppliesToId?
CommissionEntry             — append-only
  ResourceId, AppointmentId, Amount, CalculatedAt
  Status: Pending | Approved | Paid
```

---

## CI.Module.Accounting — Scope

The largest domain gap vs Xero and Comarch. Accounting is **separate from Invoicing** — Invoicing is a document store; Accounting reads from it via events.

**Rule:** Accounting never queries Invoicing or Payments DBs directly. It consumes `InvoiceIssuedEvent`, `PaymentCompletedEvent`, etc. and creates its own journal entries.

```
// Chart of accounts
AccountPlan                   — one per tenant
ChartAccount
  Id, TenantId, Code, Name, Type (Asset|Liability|Equity|Revenue|Expense)
  IsSystemAccount, ParentId?

// Double-entry ledger
JournalEntry                  — immutable once posted
  Id, TenantId, PostedAt, Description
  LinkedInvoiceId?, LinkedPaymentId?, LinkedExpenseId?
JournalLine[]                 — two or more; sum(Debit) must equal sum(Credit)
  EntryId, AccountCode, Debit?, Credit?, Description?
  ActivityCode?               — for ryczałt: tags which IncomeTaxSchemeRate applies (e.g. "pl-pkd-6201" → IT 12%)
                                null for non-LumpSum tenants; PolandCountryPlugin reads it for tax calculation

// KPiR (Polish simplified bookkeeping) is NOT a separate entity.
// It is an export format generated on demand:
//   PolandCountryPlugin.ExportFilingAsync("kpir", period) reads JournalEntry rows
//   and formats them per the legal KPiR template. Same pattern as JPK_V7.

// Live analytics — no separate reporting module
FinancialDaySummary           — one row per (TenantId, Date); updated on every write event
  TenantId, Date
  Revenue, Costs, VatCollected, VatPaid, NetIncome
  UpdatedAt
// Hours/days/weeks/months/years = range query on Date, no runtime aggregation.
// Tax simulation (zasady ogólne vs liniowy vs ryczałt) and legal-form comparison
// are pure calculations: PolandCountryPlugin.SimulateTaxScenariosAsync(tenantId, year)
// runs different formulas over FinancialDaySummary — no new storage needed.

// Expenses
ExpenseClaim
  Id, TenantId, SubmittedBy (UserId), Date, Description, Category
  Amount, Currency, VatAmount?
  Status: Draft | Submitted | Approved | Rejected | Reimbursed
  ReceiptUrl?
MileageRecord
  Id, TenantId, UserId, Date, Km (decimal), PurposeDescription
  RatePerKm (snapshot from CountryConfig), Amount

// Fixed assets
FixedAsset
  Id, TenantId, Name, Category, PurchaseDate, PurchaseValue, Currency
  DepreciationMethod: StraightLine | Declining
  UsefulLifeMonths, CurrentBookValue, LastDepreciatedAt
  IsDisposed, DisposedAt?
DepreciationEntry             — append-only
  AssetId, Period (YYYY-MM), Amount, BookValueAfter

// Bank reconciliation
BankAccount
  Id, TenantId, IBAN, BankName, Currency, CurrentBalance, LastSyncedAt?
BankTransaction               — imported, append-only
  AccountId, TenantId, ValueDate, Amount, Currency, Description
  Status: Unmatched | Matched | Ignored
  MatchedInvoiceId?, MatchedPaymentId?
```

---

## CI.Module.Legal — Scope Clarification

Legal owns all signed documents including:
- **Contracts** — this covers HR contracts too (CI.Module.HR references ContractId: Guid in Legal)
- NDA, ToS, Privacy Policy, SLA, Amendments
- Compliance tasks

CI.Module.HR does NOT have a Contract entity. It references Legal's `ContractId` for employment contracts.

---

## CI.Module.Tasks — Scope

Current state: `Project`, `WorkTask`, `TimeLog`, `TaskLabel`. Partial implementation.

**Future scope (not yet built):**
- Backlog management with priority ordering
- Gantt chart data (StartDate, EndDate, Dependencies on WorkTask)
- Party integration: a `Project` can be linked to a `Client` (OrganizationId / IndividualId)
- Client collaboration: invite external party to a project scope (limited view)
- Request exchange: both sides can create tasks/requests within a shared project

---

## Architecture Rules (enforced by CI.Kernel.ArchTests)

| Rule | Catches |
|---|---|
| Domain → no Core/Infra/API | Service logic in Domain |
| Core → no Infra/API | DB queries from service layer |
| Controllers → no DbContext | Bypassing service layer |
| Events end with `Event` | Missing suffix |
| Commands end with `Command` | Inconsistent naming |
| Handlers are sealed | Inheritance on handlers |
| Services are sealed | Inheritance on services |
| Domain → no other modules | Direct module coupling |
| Controllers have `[Authorize]` or `[AllowAnonymous]` | Accidentally public endpoint |
| Controllers have `[RequireModule]` or `[AllowWithoutModule]` | Endpoint reachable without enabling module |
| AdminControllers have `[RequireSystemAdmin]` | Unprotected admin endpoint |
| Command handlers inject IEventBus OR carry `[NoEvent]` | Write without event |
| Cross-boundary events live in CI.Kernel | Event only in module domain |
| No JSON columns on domain entities | Country/config data serialized into DB |
| No country-specific typed properties on entities | PL/DE/FR hardcoding in domain |

---

## GitHub Actions — Reusable Workflows

```yaml
# API services: build → test → Docker → GHCR → deploy
uses: MaciejMajchrzak/CI.Infra/.github/workflows/claude-service.yml@main

# NuGet packages: build → test → pack → push GitHub Packages
uses: MaciejMajchrzak/CI.Infra/.github/workflows/claude-nuget.yml@main
```

---

## System-Admin

Never impersonates. Always uses access-request flow:
1. `POST /admin/access-requests` → tenant owner approves
2. Time-limited access granted
3. Full audit trail of what was done during access window

---

## Module vs Connector

| | Module | Connector |
|---|---|---|
| Own DB | Yes | No |
| Emits domain events | Yes | Rarely |
| Has business logic | Yes | No — thin adapter only |
| References | CI.Kernel | CI.Kernel + target Module's **Domain NuGet only** |
| Example | Invoicing, Booking, HR | Slack, ComarchOptima, KSeF |

---

## Build Order

```
1. CI.Kernel                ← contracts NuGet
2. CI.Infra                 ← Docker Compose + GH Actions
3. CI.Platform.Tenants      ← validates full stack
4. CI.Platform.Users
5. CI.Platform.CountryConfig ← must exist before Invoicing, Parties, Legal
6. CI.Platform.Gateway
7. CI.Module.Parties        ← Organization, Individual, Branch
8. CI.Module.Invoicing      ← first business module
9. Everything else in parallel
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
| SeaweedFS | 9333 / 8333 / 8888 | object storage |
| OpenBao | 8200 | secrets vault |

Deploy: push to `CI.Infra` main → GitHub Actions → `docker compose` on droplet.
`keycloak-setup.sh` runs on every deploy — idempotent.
Test credentials: `test / test` on `ci-platform` realm.

---

## Key Decisions Log

| Date | Decision | Reason |
|---|---|---|
| 2026-08-02 | `tenant` as top-level naming (not workspace/namespace/org) | "org" conflicts with Party model |
| 2026-08-02 | Repo names match C# namespaces exactly | Zero mental mapping |
| 2026-08-02 | One handler, five trigger types | Business logic never knows how it was called |
| 2026-08-02 | Module manifest auto-generated | Workflow designer gains nodes automatically |
| 2026-08-02 | CI.Platform.Workflow dedicated service | Single observable place for all processes |
| 2026-08-02 | Connectors reference only Domain NuGet | Cannot touch module DB |
| 2026-08-02 | system-admin never impersonates — access-request flow | Security audit trail |
| 2026-08-02 | DevTools = dev drawer at bottom of UI, not a page | Visible on any screen |
| 2026-08-02 | Cross-boundary events in CI.Kernel | No assembly dependency between services |
| 2026-08-02 | Start RabbitMQ, add Kafka via IEventBus swap | One config line to switch transport |
| 2026-08-02 | L1 + L2 cache with Redis pub/sub invalidation | Only correct pattern for K8s horizontal scaling |
| 2026-08-02 | RowVersion = PostgreSQL xmin | No extra column, Postgres manages automatically |
| 2026-08-02 | Three-layer concurrency: Redis lock + xmin + ETag | Each layer catches what the others miss |
| 2026-08-02 | Organization + Individual = separate tables | Will accumulate different columns over time |
| 2026-08-02 | PartyRole + PartyRelationship = separate tables | Roles = business context; Relationships = ownership/governance |
| 2026-08-02 | Other modules store PartyId: Guid only | Module isolation; legal docs snapshot at creation |
| 2026-08-02 | Never call entity.Children.Clear() in handlers | Causes DbUpdateConcurrencyException in EF InMemory |
| 2026-08-03 | CI.Platform.CountryConfig as dedicated platform domain | Country law must be configurable per country, not hardcoded |
| 2026-08-03 | No JSON columns on domain entities | Typed EAV (ExtendedField tables) instead; JSON only for outbound payloads |
| 2026-08-03 | SKU not a typed property — goes in ExtendedField | SKU is business/country-specific, not universal |
| 2026-08-03 | VatRate is a named child of CountryConfig with temporal validity | Past/current/planned rates all stored; needed for invoice history |
| 2026-08-03 | ZUS modelled as TaxObligation with TaxObligationComponent children | ZUS has N components (emerytura, renta, FP, …), each with own rate and payer |
| 2026-08-03 | Branch is direct child of Organization/Individual, has own name | No intermediate BusinessProfile layer; one legal entity → N named branches |
| 2026-08-03 | Contacts are unbounded polymorphic list (Phone/Instagram/TikTok/etc.) | Real businesses have multiple phones, multiple socials |
| 2026-08-03 | BookingMode enum: FullOnly / ByPersonOnly / Mixed | Covers hotel room (Full), capacity room (ByPerson), flex room (Mixed) |
| 2026-08-03 | ResourceServiceConfig for price/duration overrides per resource | Senior stylist charges more for same service; suite room costs more |
| 2026-08-03 | Appointment lines snapshot price and name | Invoice-style immutability; service price changes don't affect past bookings |
| 2026-08-03 | Subscriptions use iCalendar RRULE | Standard, handles weekly/monthly/custom recurrence |
| 2026-08-03 | PublicDiscovery = separate service + DB | Public search never touches per-tenant module DBs |
| 2026-08-03 | OpenSearch via CI.Platform.Search abstraction | Modules push to index on write; search service never reads module DBs |
| 2026-08-03 | Catalog has three entity types: Good, Product, ServiceItem | Physical goods (stock), packaged products, time-based services are genuinely different |
| 2026-08-03 | HR contracts → CI.Module.Legal (HR stores ContractId reference only) | Contract is a legal document; HR is employment administration |
| 2026-08-03 | Payments: Stripe standard + Stripe Connect + Stripe Tap to Pay | Platform-as-marketplace needs Connect; in-person needs Terminal |
| 2026-08-03 | Workflow step states include Warning and Compensated | Real pipelines produce warnings (not just pass/fail); saga pattern needs compensation state |
| 2026-08-03 | WorkflowSignal entity for human-approval steps | External actor resumes the workflow; not a timer — genuinely async wait |
| 2026-08-03 | Frontend clients (Portal/Mobile/Public) removed from scope | User decision |
| 2026-08-03 | No CI.Platform.Scheduler — timer steps live in CI.Platform.Workflow | Workflow already owns instance state; a separate timer service would be a second place to track the same lifecycle |
| 2026-08-03 | WorkflowTimer entity with FireAt index + background poller | Persists timers across restarts; WaitUntil and WaitFor as first-class step types |
| 2026-08-03 | VatRate gets jurisdictionLevel + jurisdictionCode (nullable) | US has state/county/city sales tax; EU countries have national-only rates; same entity covers both |
| 2026-08-03 | ICountryPlugin interface for computation that cannot be generic | Config (CountryConfig) drives UI/validation; plugins drive ZUS calculation, JPK export, KSeF submission — adding a country = seed data + one plugin class |
| 2026-08-03 | CountryFilingCapability + CountryEInvoiceCapability as CountryConfig children | Drives which connectors to activate per country — declarative not hardcoded |
| 2026-08-03 | CI.Platform.Notifications as dedicated delivery service | All modules publish SendNotificationCommand; one service handles SMTP/SMS/push delivery and idempotency |
| 2026-08-03 | CI.Platform.Documents for PDF + Handlebars template rendering | Shared by Invoicing, Booking, Legal, Notifications; tenants can override platform default templates |
| 2026-08-03 | CI.Module.Marketing isolated from Booking | Loyalty/campaigns/vouchers will also apply to Catalog and future e-commerce — not a Booking-specific concern |
| 2026-08-03 | CI.Module.Accounting is double-entry ledger + KPiR + bank reconciliation + fixed assets | Largest domain gap vs Xero/Comarch; reads Invoicing and Payments via events only — never cross-queries their DBs |
| 2026-08-03 | Accounting consumes events from Invoicing and Payments, never queries their DBs | Module isolation rule applied to accounting — InvoiceIssuedEvent → journal entry |
| 2026-08-03 | VatRate renamed to ConsumptionTaxRate; IncomeTaxScheme is a separate entity | VAT/GST and income tax are fundamentally different — one goes on transactions, the other on the tenant's annual tax form |
| 2026-08-03 | IncomeTaxScheme supports Progressive/Flat/LumpSum with per-activity rates | Ryczałt can have two rates simultaneously (e.g. IT 12% + catering 3%) — ActivityCode on JournalLine tags which rate applies |
| 2026-08-03 | KPiRRecord removed — KPiR is a PolandCountryPlugin export of JournalEntry | Not a domain entity; generated on demand from existing accounting data |
| 2026-08-03 | FinancialDaySummary projection replaces a separate reporting module | Event-driven daily row covers hours/days/weeks/months/years with range queries; no runtime aggregation |
| 2026-08-03 | Tax simulation and legal-form comparison are pure calculations, no storage | ICountryPlugin.SimulateTaxScenariosAsync reads FinancialDaySummary and runs multiple formulas |
| 2026-08-03 | SeniorityLevel removed from Resource; EmployeeId? nullable FK to HR added | Seniority, skills, qualifications live in HR — Resource is the bookable slot only |
| 2026-08-03 | Stay entity groups multiple Appointments under one visit | Enables hotel room + spa + breakfast under one stay/bill; standalone appointments have StayId = null |
| 2026-08-03 | PaymentTransaction uses ProviderName + ProviderTransactionRef (no Stripe fields) | IPaymentProvider plugin pattern — swap Stripe for Mollie/Przelewy24/Adyen with one DI change |
| 2026-08-03 | WorkflowNode adds ParallelFork, ParallelJoin (All/Any/N-of-M), IsFireAndForget | Email failure must not cancel a booking — fire-and-forget = Warning, not Failure |
| 2026-08-03 | PublicDiscovery availability is event-driven; AvailabilityWorker is reconciliation only | Every booking change must reflect immediately in public availability — scheduled worker only catches drift |
