  Project

  Botchling — bot detection system for a local rAthena Ragnarok Online
  server. Research question: can automated player behavior be detected from
  game events alone?

  Architecture

  rAthena plugin (C++) → Unix pipe → Rust agent → SQS (LocalStack) → Rust
  worker → PostgreSQL → Grafana

      → MongoDB (raw events)

  Stack

  ┌───────────┬────────────┬─────────────────────────────────────────────┐
  │ Component │  Technology   │                  Notes                   │
  ├───────────┼───────────────┼──────────────────────────────────────────┤
  │ Game      │ rAthena       │ Extended via src/custom/ — NOT           │
  │ server    │               │ HPMHooking (that's Hercules)             │
  ├───────────┼───────────────┼──────────────────────────────────────────┤
  │           │               │ Writes raw binary structs to             │
  │ Plugin    │ C++           │ non-blocking Unix socket. No HTTP, no    │
  │           │               │ JSON, no threads                         │
  ├───────────┼───────────────┼──────────────────────────────────────────┤
  │ Backend   │ Rust          │ Learning project. User does Go           │
  │           │               │ professionally                           │
  ├───────────┼───────────────┼──────────────────────────────────────────┤
  │ Queue     │ SQS via       │ MVP — no Kafka, no ops overhead          │
  │           │ LocalStack    │                                          │
  ├───────────┼───────────────┼──────────────────────────────────────────┤
  │ Sessions  │ PostgreSQL    │ One table: sessions. One row per login   │
  │ DB        │               │ session                                  │
  ├───────────┼───────────────┼──────────────────────────────────────────┤
  │ Events DB │ MongoDB       │ Raw game events, dynamic schema          │
  ├───────────┼───────────────┼──────────────────────────────────────────┤
  │ Infra     │ Docker        │ docker compose up starts everything      │
  │           │ Compose       │                                          │
  ├───────────┼───────────────┼──────────────────────────────────────────┤
  │ Dashboard │ Grafana       │ Connects directly to PostgreSQL          │
  └───────────┴───────────────┴──────────────────────────────────────────┘

  Module Structure

  src/
    error.rs                        ← shared Error { message: String }
    domain.rs                       ← pub mod event; pub mod session;
    domain/
      event.rs                      ← placeholder (blocked on C++ plugin
  design)
      session.rs                    ← placeholder
    application.rs                  ← placeholder
    infrastructure.rs               ← pub mod config; pub mod logger; pub mod
  postgres; pub mod mongo;
    infrastructure/
      config.rs                     ← Config loaded from .env
      logger.rs                     ← custom JSON logger, atomic log level
      postgres.rs                   ← tokio-postgres async connection
      mongo.rs                      ← mongodb async connection
    main.rs
  Convention: no mod.rs files — use sibling foo.rs + foo/ directory (Rust
  2018+ style).

  Domain (not yet implemented)

  Core insight: model the fingerprint of automation, not specific strategies.

  Signals (invariant regardless of bot strategy):

  ┌─────────────────┬─────────────────────────────────────────────────────┐
  │     Signal      │                    Why invariant                    │
  ├──────────────────────────┼────────────────────────────────────────────┤
  │ cv_inter_action          │ Machine clock jitter ≈ 0. Computed via     │
  │                          │ Welford online algorithm                   │
  ├──────────────────────────┼────────────────────────────────────────────┤
  │ max_idle_gap_ms          │ Bots always queue next action. Humans take │
  │                          │  breaks                                    │
  ├──────────────────────────┼────────────────────────────────────────────┤
  │ chat_count               │ Bots rarely chat. Zero in a long session   │
  │                          │ is suspicious                              │
  ├──────────────────────────┼────────────────────────────────────────────┤
  │ teleport_count           │ High volume + zero chat + high kills = TP  │
  │                          │ farmer                                     │
  ├──────────────────────────┼────────────────────────────────────────────┤
  │ avg_post_tp_act_delay_ms │ Bot scans in milliseconds. Human looks at  │
  │                          │ screen first                               │
  └──────────────────────────┴────────────────────────────────────────────┘

  sessions table (one row per login):

  CREATE TABLE sessions (
      id                       BIGSERIAL PRIMARY KEY,
      account_id               INT NOT NULL,
      char_id                  INT NOT NULL,
      ip_address               INET NOT NULL,
      map                      VARCHAR(50),
      logout_at                TIMESTAMPTZ,
      cv_inter_action          FLOAT,
      max_idle_gap_ms          BIGINT,
      chat_count               INT DEFAULT 0,
      teleport_count           INT DEFAULT 0,
      avg_post_tp_act_delay_ms FLOAT,
      stddev_post_tp_act_delay FLOAT,
      bot_score                SMALLINT,
      label                    VARCHAR(10)
  );
  account_profiles is a free VIEW — GROUP BY account_id over sessions. No
  extra logic.
  
  Bot score (0–100, fixed rules):

  ┌──────────────────────────────────────────┬────────┐
  │                   Rule                   │ Weight │
  ├──────────────────────────────────────────┼────────┤
  │ cv_inter_action below threshold          │ +30    │
  ├──────────────────────────────────────────┼────────┤
  │ max_idle_gap_ms below threshold          │ +25    │
  ├──────────────────────────────────────────┼────────┤
  │ chat_count zero in long session          │ +20    │
  ├──────────────────────────────────────────┼────────┤
  │ avg_post_tp_act_delay_ms below threshold │ +25    │
  └──────────────────────────────────────────┴────────┘

  0–30 = likely human · 31–70 = suspicious · 71–100 = likely bot

  Worker in-memory state per active session:
  struct SessionState {
      account_id, char_id, ip, login_at, map,
      welford: WelfordState,     // Welford online for cv_inter_action — O(1)
  per event
      last_event_at,
      max_idle_gap_ms,
      chat_count, teleport_count,
      last_tp_at, post_tp_delays: Vec<f64>,
  }
  On Logout: finalize signals → compute score → INSERT one row to sessions.

  GameEvent (blocked)

  Shape is dictated by the C++ plugin. Cannot be designed until:
  1. Binary struct layout of the Unix pipe messages is defined
  2. Fields per event are known (e.g. does walk carry coordinates? timestamp
  source?)
  3. Timestamp strategy decided (rAthena-side vs Rust-side on read)

  Events the plugin will capture:
  login, logout, walk, teleport, map_change, monster_killed, item_picked,
  chat_sent

  Next step: design the C++ plugin structs first, then mirror them in Rust as
  GameEvent.

  Key Decisions Made

  - Async runtime: Tokio. Required because aws-sdk-sqs and mongodb are
  async-only.
  - PostgreSQL driver: tokio-postgres directly (not sqlx, not the sync
  postgres wrapper).
  - MongoDB driver: mongodb async client — never mongodb::sync::Client inside
  Tokio (deadlocks).
  - Credentials: always use builder APIs (PgConfig::new(),
  Credential::builder()) not URI strings — passwords contain special
  characters.
  - Migrations: refinery wired to tokio-postgres. Files in
  infrastructure/postgres/migrations/V{n}__{desc}.sql. Append-only.
  - HTTP server: Axum, when needed. Not needed for MVP — Grafana reads
  PostgreSQL directly.
  - Queue: SQS (LocalStack). Not Kafka.

  Explicitly Out of Scope

  ML, Kafka, Kubernetes, client-side anti-cheat, kernel drivers, MongoDB for
  sessions, farm detection / cross-account clustering (Phase 2), Markov
  chains, path repetition score, direction entropy, pos_radius/centroid.

  Docker

  botchling-postgres  → localhost:5432
  botchling-mongodb   → localhost:27017
  .env must use localhost for both hosts (not Docker service names — those
  only resolve inside the Docker network).
  
  Experiments Planned

  ┌───────┬─────────────────────────────────────────┐
  │ Group │               Description               │
  ├───────┼─────────────────────────────────────────┤
  │ A     │ Casual human                            │
  ├───────┼─────────────────────────────────────────┤
  │ B     │ Tryhard human (intense farm, no breaks) │
  ├───────┼─────────────────────────────────────────┤
  │ C     │ Default OpenKore                        │
  ├───────┼─────────────────────────────────────────┤
  │ D     │ OpenKore with random delays             │
  └───────┴─────────────────────────────────────────┘

  Validation: plot cv_inter_action vs avg_post_tp_act_delay_ms in Grafana. If
  the two populations separate visually, Phase 2 is worth building.

  Known Evasions

  - Account rotation: 24 accounts × 1h each looks normal per-session. Needs
  cross-account analysis (Phase 2).
  - Random delays: degrades cv_inter_action signal. Threshold needs tuning.
  - Fixed rules are public: if open source, bot operators tune OpenKore to
  pass.
