# RAIDO 2.28.0 — Ice

Today is the default tab. Today, Roster, Fleet and More share the approved Ice
palette, SF Symbols, type hierarchy, soft cards and spacing. Ice Dark uses the
same layout with adaptive navy surfaces. Settings supports Ice, Ice Dark or
System, and the first launch of this release selects Ice once.

Today keeps its saved-route map in the header. Pull down or tap the handle to
expand it; use the handle to collapse. The expanded map keeps existing GPS,
recenter and map-source controls. The compact map is passive and does not start
another location session. Pickup appears first, followed by alcohol/rest
awareness and the duty agenda. Crew is available per sector; role selections,
documents, notes, transport, announcements and Calendar export remain available.

The offline basemap now uses bundled Natural Earth 1:50m land outlines rather
than rough silhouettes, with the same Ice sea/land colors as the approved
header. Outlines are decoded once, culled by bounds before projection and drawn
asynchronously. Source: https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_50m_land.geojson
Natural Earth data is public domain: https://www.naturalearthdata.com/about/terms-of-use/.
Only land outlines are drawn; this is a route overview, not a navigation chart.

Roster has a borderless month calendar with round date selection, existing duty
codes and report times, change indicators and accessible labels. Its selected
day uses the same pickup/agenda cards as Today. Full briefings, calendar/list
switching, month navigation, roster changes and earnings remain available.

Fleet has its own tab, using the existing indexed, bounded refresh engine.
Polling is explicitly cancelled while another tab is selected. Aircraft details
retain photos and public tracking. More contains Live RAIDO, Earnings, Crew
Documents, Announcements, Manuals, Crew Control and Settings. Diagnostics is
inside Settings. Manuals points to the original portal; this release does not
introduce a new manual catalogue. The retained WKWebView preserves the current
portal page; its handler weakly references the browser model to avoid a cycle.

## Airport clocks

Destination clocks use bundled IANA time zone identifiers, not fixed UTC
offsets or a network request. iOS applies its installed DST rules. An unknown
airport explicitly shows an unavailable clock rather than substituting the
phone’s time. Data is derived from the OpenFlights airports database:
https://github.com/jpatokal/openflights/blob/master/data/airports.dat
retrieved 2026-10-04. AirportTimeZones.json contains city/timezone pairs only.
OpenFlights data attribution and database license:
https://openflights.org/data.html#license — Open Database License (ODbL) 1.0.
This derived table is distributed under the same license.
Common airport overrides remain in the existing CrewCompanionTimeZones table.

## Validation

The full patch chain must apply from the repository baseline and Ice must be
idempotent. CI compiles the generated iPhoneOS sources, runs existing sensor,
Fleet, earnings, documents and announcement checks, validates all bundled time
zone identifiers and date-sensitive offset scenarios, and renders all four tabs
plus the expanded map in light/dark iPhone simulator screenshots. Synthetic
preview data exists only in the temporary simulator host and never in the IPA.

This release changes presentation, not the existing offline arming gate. Manual
flight arming remains pending. Native map content, actual duty data, iOS chrome
and Dynamic Type can differ from the design image; screenshots show the actual
implementation.
