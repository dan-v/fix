//! Per-thread worker id. The main thread that called `Engine.evaluate`
//! is worker 0. Helper threads spawned by the scheduler set this in their
//! loop. Code that needs per-worker storage (heap TLABs, etc.) reads it.

pub threadlocal var current: u8 = 0;

/// True on a compute-worker thread (worker 0 or a scheduler helper) once it
/// has entered its drain loop; false on every other thread — the IO runtime,
/// the daemon connection pool, and spawned fetch threads. Those threads also
/// publish futures and thus run waiter `wake_fn`s, but their `current` is a
/// meaningless default: this flag lets a wake distinguish "resolved by a
/// compute worker (its core is cache-hot for the value)" from "resolved by an
/// IO thread (no useful locality)" so resolver-affinity routing only fires for
/// compute workers. Set alongside `current` at the two worker-loop entries.
pub threadlocal var is_worker: bool = false;
