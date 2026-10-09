# Aircraft network resilience

AircraftHTTPClient is shared by Fleet, Flight Companion and photo metadata.
It spaces request starts per host, honours Retry-After, and stops contacting a
failing provider during exponential cooldowns with bounded jitter. Cancellation
is cooperative during pacing and URLSession requests. A late parallel success
cannot clear a newer rate-limit cooldown.

ADS-B responses are cached in memory for 10 seconds, route responses for 60
seconds and photo metadata for one hour, with at most 128 entries, a 2 MiB
per-entry limit and a 4 MiB total data budget. Each entry retains its original receipt time. Existing Fleet
observations remain visible through outages with their original age. No new
background polling is introduced.

Reviewed on 9 October 2026 using the providers' own documentation:

- adsb.fi public API: one request per second; personal, non-commercial use;
  attribution and a home-page link required. The client uses a 1.05-second
  start interval. https://github.com/adsbfi/opendata
- ADSB.lol: dynamic rate limits and ODbL data licence. The interactive API
  documentation asks production users to contact its maintainer. The client
  uses a conservative 0.3-second interval and observes returned rate limits.
  https://github.com/adsblol/api and https://api.adsb.lol/docs
- adsb.one: current terms could not be verified from an accessible official
  page. Its fallback requests are conservatively spaced 1.05 seconds apart;
  this is an application choice, not a claim about the provider's limit.
- Planespotters: use the provided thumbnail, retain the photographer credit,
  and link to the original photo. Photo credit displays © Photographer.
  https://www.planespotters.net/legal/termsofuse

Technical request controls do not establish employer approval or a provider's
permission for commercial distribution. Those decisions remain with the owner.

Native tests use URLProtocol fixtures, never public endpoints. They exercise
response timestamp preservation, POST cache separation, concurrent pacing,
rate-limit and connection-failure circuits, cancellation and host rejection.
The existing executable Fleet-store integration check still tests real store
concurrency, cancellation and immediate restart with an isolated client.
