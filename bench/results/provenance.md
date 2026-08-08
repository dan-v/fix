# Benchmark provenance

Stale: the committed summary images predate the current lane structure
(they still show the pre-redesign rows) and carry no provenance record.
Run `./bench/run` to regenerate this directory with real measurements —
it replaces this file with the full record (date, hardware, run settings,
tool versions, pins, and the measured commit).
