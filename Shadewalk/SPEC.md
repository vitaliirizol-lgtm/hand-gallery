# Shadewalk — product & engineering spec

Native iOS app that plans **walking routes through the shade**. It works out where buildings and trees cast
shadows for the chosen departure time (sun position + building heights + tree canopy) and routes you so you
spend the least time in direct sun, without an unreasonable detour.

Inspired by the *concept* of shade-aware walking navigators (e.g. the Korean student app shown in the reference
TikTok). Everything here — name, icon, visual design, copy — is original. Do **not** reuse any third-party
branding, icon, screenshots, or UI text.

---

## 1. Features (v1)

| # | Feature | Notes |
|---|---------|-------|
| F1 | **Map home** | Full-screen MapKit map, floating search ("Where to?"), weather pill (temp, feels-like, UV), my-location, layers button. |
| F2 | **Shade overlay** | Toggle that draws building shadows + tree-canopy shade for the selected time as translucent polygons. |
| F3 | **Departure-time slider** | "Now" ↔ any time today between sunrise and sunset; sun-gradient track; recomputes shade + routes (area data cached, so only shade+routing rerun). |
| F4 | **Shade-aware routing** | 2–3 alternatives: *Shadiest*, *Balanced*, *Fastest* (deduped when identical). Selected route drawn with shaded runs in green and sunny runs in orange. Map pills label each route ("Shadiest · 14 min"). |
| F5 | **Route card** | Title (profile), `18 min · 1.4 km · 1,898 steps`; chips: Shade %, Slope (flat/gentle/moderate/steep), Sun time; counters: crosswalks, stairs, underpasses; slope profile bar chart (start → arrival, bars coloured by grade) using Open-Meteo elevation; cool spots on the way. Buttons: **Start**, Save. |
| F6 | **Follow mode** | Live navigation: camera follows user, maneuver banner ("Turn left onto X · 80 m"), "In shade now / Sun for next 120 m" indicator, remaining time/distance/ETA, off-route → reroute, arrival detection, haptics. |
| F7 | **Cool spots** | Map layer + list: drinking water, indoor cool places (library, mall, community centre), shelters, parks. Filter chips. "Shady route here". |
| F8 | **Seat side** (transit) | From/To + vehicle (bus/tram/train) + departure → "Sit on the LEFT — the sun hits the right side for 78% of the trip". Top-down vehicle diagram + trip timeline. Uses MapKit driving path as the road proxy. Handles sun-down / overcast ("either side is fine"). |
| F9 | **Saved places** | Home / Work / favourites + recent searches (SwiftData). |
| F10 | **Settings** | Shade preference (max detour 0–50 %, default 25 %), walking speed, avoid stairs, units, default overlay on/off, data attribution (© OpenStreetMap contributors, Open-Meteo), about. |
| F11 | **Onboarding** | 3 pages: concept → how it works (sun + buildings + trees) → location permission. |
| F12 | **Localization** | English (source), Russian, Ukrainian via `Localizable.xcstrings`. |

Tabs: **Walk** (map + routing + cool spots + follow mode), **Seat side**, **Saved**, **Settings**.

## 2. Data sources (no API keys)

* **OpenStreetMap via Overpass API** — buildings (`height`, `building:levels`, `min_height`), trees
  (`natural=tree`, `tree_row`), canopy polygons (`natural=wood`, `landuse=forest`), walk network
  (`highway=*`), crossings, covered/underpass ways, cool spots. Mirrors (try in order, with retry/backoff):
  `https://overpass-api.de/api/interpreter`, `https://overpass.kumi.systems/api/interpreter`,
  `https://overpass.private.coffee/api/interpreter`. Disk cache (7 days).
* **Open-Meteo** — forecast (`temperature_2m, apparent_temperature, uv_index, cloud_cover, is_day`, hourly) and
  elevation (`/v1/elevation`, ≤ 100 coords per request).
* **MapKit** — map rendering, place search (`MKLocalSearchCompleter`/`MKLocalSearch`), driving paths for seat side.
* **CoreLocation** — user location/heading.

## 3. Architecture

```
Shadewalk/
  SPEC.md
  project.yml                      XcodeGen spec  (Shadewalk.xcodeproj is generated from it)
  Shadewalk/                       iOS app target (SwiftUI, MapKit, CoreLocation, SwiftData, Charts)
  ShadewalkTests/                  app-level tests (iOS only)
  Packages/ShadeCore/              Swift package — pure Foundation + Observation, builds & tests on Linux
    Sources/ShadeCore/             algorithms, models, data clients
    Sources/ShadeFeatures/         @Observable view models / state machines (no SwiftUI/MapKit imports)
    Tests/ShadeCoreTests/
    Tests/ShadeFeaturesTests/
```

Rules:

* `ShadeCore` and `ShadeFeatures` import **only** `Foundation`, `Observation` (and `FoundationNetworking` under
  `#if canImport(FoundationNetworking)`). No `CoreLocation`, `MapKit`, `simd`, `UIKit`, `SwiftUI`, `os`.
  They must build and test on Linux (Swift 6.3.1 toolchain at
  `/opt/swift/swift-6.3.1-RELEASE-ubuntu24.04/usr/bin`) and on iOS 17+.
* `swift-tools-version: 5.9`, Swift 5 language mode. Platforms: iOS 17, macOS 14.
* All public model types are `Sendable` value types. Long-lived services are `actor`s or `final class … : @unchecked Sendable`
  with immutable state.
* The iOS app target contains SwiftUI views and thin adapters that implement the protocols in
  `ShadeCore/Model/Protocols.swift` with MapKit/CoreLocation.
* Tests use **XCTest** (works on Linux and Xcode).
* Build/test command: `cd Shadewalk/Packages/ShadeCore && swift build && swift test`
  (use `--scratch-path /tmp/<unique>` if several builds may run at once).

## 4. Core algorithms

### 4.1 Projection & geometry (foundation, `Geometry/`)
Local equirectangular projection around an origin (`LocalProjection`) — metres east (`x`) / north (`y`).
Accurate enough for areas < 10 km. All shadow/graph maths happens in projected metres.

### 4.2 Sun position (`Solar/SolarCalculator.swift`)
NOAA solar position algorithm (Julian century → geometric mean longitude/anomaly → equation of centre →
apparent longitude → declination, equation of time → true solar time → hour angle → zenith/azimuth),
with atmospheric-refraction correction. Azimuth in degrees clockwise from true north `[0, 360)`; elevation in
degrees. Sunrise/sunset at elevation −0.833°. Accuracy target ≤ 0.1° vs NOAA calculator.

### 4.3 Shade (`Shade/ShadeEngine.swift`)
* Sun up iff `elevation > 0`. If the sun is down, everything counts as shaded (fraction 1).
* **Buildings**: point `P` is shaded if the ray from `P` towards the sun (`dir = (sin az, cos az)`) enters a building
  footprint at horizontal distance `t` with `height > t · tan(elevation)` (and, if `minHeight > 0`,
  `minHeight < t · tan(elevation)` must hold for the ray to pass *under* it — i.e. shade only if the ray hits the
  solid part between `minHeight` and `height`). Points inside a footprint are shaded. Ray length is capped at
  `min(maxBuildingHeight / tan(elevation), 400 m)`. Buildings are indexed in a uniform grid (≈ 25 m cells).
* **Roof-only structures** (`building=roof`, canopies): points inside the footprint are shaded; they also cast
  shadow like a building with `minHeight` = their min height (default 2.5 m).
* **Trees**: canopy disc of radius `crownRadius` centred at the trunk position offset by
  `0.7 · height / tan(elevation)` (capped at 60 m) in the anti-sun direction. Point inside disc → shaded.
* **Canopy areas** (woods/forest polygons): shaded inside the polygon (also offset like trees, cap 30 m).
* Covered ways (`covered=yes|arcade|colonnade`, `tunnel=*`, `indoor=yes`) are always fully shaded.
* Per-edge shade fraction: sample every 5 m (at least 2 samples), fraction = shaded samples / samples.
* Overlay polygons: for each building, convex hull of footprint ∪ footprint translated by the shadow vector;
  tree shadows as 12-gon discs; capped to the requested bbox and a max polygon count (e.g. 4 000).

### 4.4 OSM → AreaData (`OSM/`)
* Overpass query (`[out:json][timeout:90]`, bbox `s,w,n,e`): walkable `highway` ways (`out geom` — keeps node ids and
  inline geometry), crossing/traffic-signal nodes, buildings (ways + multipolygon relations, `out geom`),
  trees / tree rows / wood / forest, cool-spot POIs (`amenity=drinking_water|water_point|library|community_centre|shelter`,
  `shop=mall|department_store`, `leisure=park`) with `out center` for areas.
* Heights: `height` (parse `12`, `12 m`, `12.5m`, `40'`/`40 ft`), else `building:levels × 3.2 + roof:levels × 1.5`,
  else defaults by `building=` value (house/detached/residential/terrace 7 m, apartments 18 m,
  commercial/office/retail/hotel 14 m, garage/garages/shed/kiosk/carport/hut 3 m, roof 4 m, other 9 m).
  `min_height` or `building:min_level × 3.2`. Roof-only structures (`building=roof|carport|canopy`, `walls=no`)
  default to 4 m with a 2.5 m underside. Objects built from ways/relations that share an id space with nodes
  (cool spots, relation rings, tree-row samples) get negative synthetic ids.
* Walkable: `footway, pedestrian, path, steps, living_street, residential, service, unclassified, track,
  cycleway (unless foot=no), tertiary, secondary, primary (+ `_link`), corridor, bridleway(foot=yes)`.
  Excluded: `motorway, trunk (+_link)` unless `foot=yes|designated`; any way with `foot=no`; `access=private|no`
  unless `foot=yes|designated|permissive`; `area=yes` ways are skipped in v1.
* Graph: split ways at nodes shared by ≥ 2 walkable ways and at way endpoints; each edge keeps its inline
  geometry; drop edges < 0.5 m; keep the largest connected component.

### 4.5 Routing (`Routing/`)
* Snap origin/destination to the nearest edge (projection onto edge geometry via a grid index), max 250 m away
  (else `ShadeError.originTooFarFromNetwork`). Temporary virtual nodes split that edge.
* A* with straight-line heuristic (all cost multipliers ≥ 1 so it stays admissible).
* Base cost per edge: `length × classPenalty` (footway/pedestrian/path/sidewalk 1.0, living_street/residential/service 1.05,
  minor road 1.1, major road 1.2) + stairs `length × (avoidStairs ? 6 : 1.4)` + 12 m-equivalent per crossing node.
* Shade cost: `base × (shade + (1 − shade) × (1 + k))`, k = sun penalty.
* **Fastest** = k 0. **Shadiest** = for k in `[0.5, 1, 2, 4, 8, 16]`, take the route with the fewest sunny metres whose
  length ≤ fastest × (1 + maxDetourFraction). **Balanced** = k 1 (only if distinct and within detour cap).
  Routes identical to another are merged (`profiles` lists all).
* Route metrics: distance, duration (`distance / speed + 10 s × crossings + stairs slowdown`), steps
  (`distance / strideLength`), shaded/sunny distance & durations, crosswalks, stairs, underpasses, maneuvers
  (turn angle buckets: <20° continue, <45° slight, <135° turn, else sharp/u-turn; also cross-street / stairs events),
  segments = runs of shaded / sunny coordinates (from `ShadeEngine.shadeRuns`).
* Elevation: after routing, sample ≤ 60 points per route (all routes in one Open-Meteo call ≤ 100 coords when
  possible), build `ElevationProfile` (12 bins, ascent/descent, max grade; category by |grade|: flat < 1.5 %,
  gentle < 4 %, moderate < 8 %, steep ≥ 8 %).

### 4.6 Seat side (`Transit/SeatSideAdvisor.swift`)
Walk the driving path in 30 s steps at constant speed (`duration` given). For each step: heading = bearing of the
current segment, sun at that time. Relative angle `rel = sunAz − heading` normalised to `[0, 360)`; sun on the
**right** if `rel ∈ (15, 165)`, **left** if `(195, 345)`, else ahead/behind; none if sun down. Weight =
`|sin rel| × cos(elevation)`. Recommendation: sit on the side **opposite** the dominant sun side if its share ≥ 15
percentage points more; `either` otherwise; reasons `.sunDown`, `.overcast` (cloud cover ≥ 85 %), `.balanced`.

### 4.7 Route progress (`Navigation/RouteProgressTracker.swift`)
Projects each location fix onto the route polyline (search window ahead of last progress to avoid jumping to a
parallel leg), returns distance along, remaining distance/duration, next maneuver & distance to it, whether the
current position is in a shaded run, length of the next sunny stretch, off-route (> 35 m for 3 consecutive fixes or
> 80 m once with good accuracy), arrival (< 20 m from destination or ≥ 98 % progress).

### 4.8 Planning (`Services/RoutePlanner.swift`)
Validates coordinates and the 5 km straight-line limit (`ShadeError.tooFar`), then fetches (or reuses) the area
`box(origin, destination) + 300 m` (min 800 m a side). In memory it keeps ≤ 3 areas (LRU; a request inside a cached or
in-flight area reuses it), one `ShadeEngine` per area, and edge shade per area per departure rounded to 5 min (sun at
the area centre at the rounded time). Route sun = sun at the trip midpoint at the exact departure. Elevation (one
Open-Meteo call for all routes when ≤ 100 samples) and weather (forecast reused 15 min within 2 km) run concurrently;
their failures are non-fatal. Origin and destination < 5 m apart give a trivial one-route plan (no snapping).
Cancellation throws `ShadeError.cancelled`; a cancelled caller stops waiting at once, while its area fetch finishes and
is cached. Overlay: empty (no fetch) when the sun is down or the box side exceeds 3 km. Cool spots: cached area, else
the provider's `CoolSpotProviding`, else an area fetch.

## 5. Module ownership (for parallel work)

Foundation (already written, change only via the integration step): `Model/*`, `Geometry/*`, `Services/HTTPClient.swift`.
Each module below owns the listed files and their tests. Stubs exist with the final public signatures — replace the
bodies, keep the signatures (adding public API is fine; changing/removing it is not).

| Module | Files | Tests |
|---|---|---|
| solar-transit | `Solar/SolarCalculator.swift`, `Transit/SeatSideAdvisor.swift` | `SolarCalculatorTests`, `SeatSideAdvisorTests` |
| shade | `Shade/*` | `ShadeEngineTests` |
| osm | `OSM/*` | `OSMParserTests`, `WalkGraphBuilderTests` (+ `Tests/ShadeCoreTests/Fixtures/*.json`) |
| routing | `Routing/*` | `WalkRouterTests`, `ElevationProfileTests` |
| services | `Services/OverpassClient.swift`, `Services/OpenMeteoClient.swift`, `Services/DiskCache.swift`, `Services/StableHash.swift` | `OverpassClientTests`, `OpenMeteoClientTests`, `DiskCacheTests` |
| features | `Navigation/*`, `Sources/ShadeFeatures/*` | `RouteProgressTrackerTests`, `Tests/ShadeFeaturesTests/*` |
| integration | `Services/RoutePlanner.swift` | `RoutePlannerTests`, `EndToEndTests` |

## 6. Visual design (app layer)

Original "Shadewalk" look — calm, cool, legible in harsh sunlight.

* Colours (light / dark): `shade` deep green `#0E7A55` / `#3DDC97`; `shadeSoft` `#DDF5EA` / `#123528`;
  `sun` orange `#FF8A2A` / `#FF9F4D`; `heat` red `#E5484D`; `ink` `#0F1A17` / `#F2F7F5`; `inkSecondary` 60 %;
  `surface` white / `#101615`; `canvas` `#F3F7F5` / `#070B0A`; accent = `shade`.
* Typography: SF Pro; numbers in `.rounded` design, heavy weights for big metrics (`18 min`).
* Shapes: 20 pt continuous corner cards, 999 pt capsule chips, soft shadows; materials (`.regularMaterial`) for
  floating map controls.
* Map: `.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll)`; shade overlay
  polygons in `ink` at 18 % opacity; selected route 7 pt stroke, alternates 5 pt in `inkSecondary`.
* Icon: original — teal→mint gradient tile, white winding footpath disappearing under a dark leaf-shaped shadow,
  small warm sun disc top-right.
* Motion: spring animations for sheets/cards, haptic ticks on slider hour marks and maneuvers.
* Accessibility: Dynamic Type, VoiceOver labels on all controls/metrics, never colour-only (shade/sun also by
  pattern/label), respects Reduce Motion.
