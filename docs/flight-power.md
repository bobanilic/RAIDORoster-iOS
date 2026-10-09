# Flight Companion power modes

Settings → Flight Companion → Save battery during flight is enabled by default.
The preflight location and motion session still detects takeoff. After takeoff,
the saved route and measured departure time drive an explicitly estimated marker.
GPS, both motion/barometer observers, ADS-B polling and airport wake monitoring
stop. The foreground timer redraws the estimate; it stops on background entry.
Reopening the app advances the model using elapsed time rather than background work.

Improve accuracy runs a foreground GPS-only session for at most 45 seconds, or
until an acceptable recent fix arrives. Cancel, screen lock, denied permission,
completion and Stop clean up the session. Measured fixes re-anchor the estimate
and can enter the measured trail. Estimated positions never enter that trail.

With sensors disabled there is no measured touchdown time. Route-model arrival
and the subsequent session end are labelled estimated. The last selected mode
persists. Turning battery saving off restores the continuous tracking option.

The older diagnostic observer previously started at every app launch and had no
stop path. It now follows the tracking session's motion resource policy too.

Native policy tests cover preflight, cruise, descent, foreground accuracy fixes,
background entry, continuous tracking, estimated arrival, idle and complete.
Actual energy consumption and GPS reception need a device flight test; simulator
checks do not measure either. No percentage reduction is claimed.
