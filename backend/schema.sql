-- Opt-in shared trips (see src/trip.ts). No IP address, exact place or date is stored:
-- `month` is the calendar month of the trip, `received` the month the row arrived.
CREATE TABLE IF NOT EXISTS trips (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  received TEXT NOT NULL,
  angler TEXT NOT NULL,
  digest TEXT NOT NULL,
  gh TEXT NOT NULL,
  month INTEGER NOT NULL,
  water TEXT NOT NULL,
  species TEXT NOT NULL,
  hours REAL NOT NULL,
  catches INTEGER NOT NULL,
  payload TEXT NOT NULL,
  UNIQUE (angler, digest)
);
CREATE INDEX IF NOT EXISTS trips_angler ON trips (angler);
