# Device-local roster and flight state

Roster, month and change caches use versioned JSON envelopes, atomic writes,
iOS complete-until-first-authentication file protection and backup exclusion.
The existing unwrapped JSON files migrate when read. Saved roster months are
retained: they can be needed for historical earnings.

Flight session, completed-sector state and measured trails move from
UserDefaults to the same protected storage. Legacy entries are removed only
when a successful protected write completes; an authoritative protected file
wins over a stale defaults duplicate. Legacy trails are migrated in a yielding
main-actor task so the UI can process input between files. Trail filenames are
SHA-256 hashes of the session key. Inactive trail files expire after 30 days;
the active session's trail is retained. A legacy trail without a saved timestamp
starts that retention period at migration.

Storage failures are logged by operation and error domain/code, without roster
contents, signed URLs or contacts. Corrupt or unknown future schemas are
preserved rather than overwritten. If the device has not yet been unlocked,
flight restoration is retried on the protected-data-available notification.

This uses iOS data protection, not independent application encryption. The
Documents vault retains its existing encryption and stronger locked-device
protection. User-facing notes and Fleet caches remain separate follow-up work.
