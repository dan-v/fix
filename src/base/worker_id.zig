//! Per-thread worker id. The main thread that called `Evaluator.evaluate`
//! is worker 0. Helper threads spawned by the scheduler set this in their
//! loop. Code that needs per-worker storage (heap TLABs, etc.) reads it.

pub threadlocal var current: u8 = 0;
