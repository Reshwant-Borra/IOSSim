# Custom Profiles

Profiles include stationary, constant apparent speed, acceleration, deceleration, city, suburban, highway, and intentionally unrealistic negative controls.

Inputs include host-planned apparent speed, requested distance, update interval, bounded timing variation, transition duration, method, and deterministic seed. The route is truncated at the requested distance with an interpolated final coordinate.

The same route, settings, interval, and seed produce the same planned sequence. Saved browser profiles contain configuration only; generated experiment records are stored by the backend.
