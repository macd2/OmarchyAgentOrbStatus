// Agent Pulse — a pixel-art orb for the Omarchy bar.
//
// Same idea as the floating Agent Orb (a noise-displaced sphere with a 4-colour
// iridescent gradient), rebuilt for a 21x21 slot: the sphere is rasterised one
// pixel at a time, its hue is hard-quantised to the four palette anchors instead
// of bilinearly blended, and its lighting is dithered down to a handful of
// levels with a 4x4 Bayer matrix. Nothing about the bar version reads as the
// floating one beyond the sphere itself — the mesh, the gradient and the smooth
// shading are all gone.
//
// The sphere is cut into three horizontal bands, one per agent source. Each
// band's displacement and brightness follow that agent's own activity, so the
// silhouette bulges where work is happening: a per-agent readout in the shape
// of an orb.
//
// Follows the first-party widget contract: extends BarWidget, keeps
// moduleName, and hands its visual to BarIconButton as an iconComponent so the
// bar's optical alignment, hover tooltip and click plumbing come from the host.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.macd2.agent-pulse"

  // ------------------------------------------------------------- agent data
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string statePath:
      (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") +
      "/omarchy/agent-watch/state.json"
  // Prefer this plugin's own copy of the watcher, then the one that ships with
  // the floating orb. The watcher is a singleton (pid lockfile) and both
  // plugins read the same state file, so whichever gets there first owns it.
  readonly property string watcherScript:
      Quickshell.env("AGENT_ORB_WATCHER") ||
      (home + "/.config/omarchy/plugins/io.github.macd2.agent-pulse/watcher/agent-watcher.sh")

  // The watcher owns the agent registry; this widget never duplicates the list.
  readonly property string orbId: "io.github.macd2.agent-orb"

  property var state: ({})
  property double lastAt: 0
  property var laneAt: ({})
  property var laneBusy: ({})         // { opencode: true, ... } tight "right now" flag
  property var level: [0, 0, 0, 0]    // 0..1 per band, smoothed every frame

  // The registry has two dozen entries and the sprite has room for a handful of
  // bands, so bands are assigned by recency: the agents that touched a file most
  // recently take the orb, and everything else waits its turn. That keeps the
  // sprite at a readable band size no matter how many agents are installed.
  readonly property int maxBands: 4
  readonly property var bands: bandOrder()
  property real motion: 0             // smoothed "is work happening right now"

  function bandOrder() {
    var list = []
    var src = root.state.agents || []
    for (var i = 0; i < src.length; i++) list.push(src[i])
    list.sort(function (a, b) {
      // Busy agents outrank merely-recent ones, so a live agent never loses its
      // band to an idle one that happened to write a second ago.
      var ab = a.busy ? 1 : 0, bb = b.busy ? 1 : 0
      if (ab !== bb) return bb - ab
      return (b.last || 0) - (a.last || 0)
    })
    return list.slice(0, root.maxBands)
  }

  function levelOf(id) {
    var at = Number(root.laneAt[id]) || 0
    return at > 0 ? Math.max(0, 1 - (Date.now() - at) / 6000) : 0
  }

  // ------------------------------------------------------------- appearance
  // Four anchors spread around the hue wheel so the orb still reads as
  // iridescent on a near-monochrome theme.
  readonly property color hueA: Color.accent
  readonly property color hueB: Color.popups.border
  readonly property color hueC: Color.notifications.countdown
  readonly property color hueD: Color.tooltip.border

  readonly property real levels: 5      // dithered shading steps
  property double phase: 0
  property double lastTickMs: 0
  property int frameMs: 16           // adaptive: converges on the achievable rate

  // ------------------------------------------------------------------ data
  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyState(text())
    // No state file at all: nothing is watching yet, so start it.
    onLoadFailed: root.claimWatcher()
  }

  function applyState(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "{}")) } catch (e) { return }
    if (!parsed || typeof parsed !== "object") return
    root.state = parsed
    if (parsed.perSource) root.laneAt = parsed.perSource
    if (parsed.busy) root.laneBusy = parsed.busy
    var at = Number(parsed.at) || 0
    if (at > root.lastAt) root.lastAt = at
  }

  // ---------------------------------------------------------------- watcher
  // Never restarted on exit: the orb plugin may already own the lock, and
  // respawning would spin against it. Adopt instead, and only re-claim when the
  // state file has stopped being refreshed.
  Process {
    id: watcher
    running: false
    command: ["/bin/bash", root.watcherScript]
  }

  property bool claimed: false
  function claimWatcher() {
    if (root.claimed) return
    var age = Date.now() - (Number(root.state.now) || 0)
    if (age < 20000) return
    root.claimed = true
    watcher.running = true
  }

  Timer {
    interval: 20000
    repeat: true
    running: true
    onTriggered: root.claimWatcher()
  }

  Component.onCompleted: root.claimWatcher()

  // ------------------------------------------------------------------ clock
  // Two signals with different jobs. `level` is the long 6s glow tail, which is
  // what makes a band swell and stay lit after work stops. `motion` is the tight
  // busy flag, and only that one drives spin, sweep and breathing — otherwise the
  // orb keeps tumbling for six seconds after every message, which at 21px reads
  // as constant jitter rather than as activity.
  Timer {
    id: tick
    // Adaptive, for the same reason as the floating orb: asking a software-GL
    // compositor for 60fps just backs the queue up and delivers frames in
    // bursts. Converging on the achievable rate makes them evenly spaced.
    interval: root.frameMs
    repeat: true
    running: true
    onTriggered: {
      var now = Date.now()
      var dt = root.lastTickMs > 0 ? (now - root.lastTickMs) / 1000 : 1 / 60
      if (dt > 0) {
        // Track the achieved rate instead of nudging on a threshold: the old
        // form grew on any spike but shrank far more slowly, so it ratcheted
        // up and stuck. Capped at 150ms so it can never drop under ~7fps.
        var target = Math.min(150, Math.max(16, dt * 1000 * 1.15))
        root.frameMs = target > root.frameMs
          ? Math.min(target, root.frameMs * 1.3 + 2)
          : Math.max(target, root.frameMs - 4)
      }
      root.lastTickMs = now
      var bs = root.bands
      // A fresh array each tick: assigning the same mutated object back would
      // not emit a change signal, and every band binding would freeze.
      var next = []
      var moving = 0
      for (var i = 0; i < root.maxBands; i++) {
        var b = bs[i]
        var want = b ? root.levelOf(b.id) : 0
        var cur = root.level[i]
        var k = 1 - Math.pow(want > cur ? 0.00004 : 0.0004, 1 / 60)
        next.push(cur + (want - cur) * k)
        if (b && b.busy && want > 0.15) moving = 1
      }
      root.level = next

      // Motion rises quickly and falls slowly: a burst should catch the eye, but
      // a flicker between messages should not spin the orb up.
      var mk = 1 - Math.pow(moving > root.motion ? 0.000002 : 0.0006, 1 / 60)
      root.motion += (moving - root.motion) * mk
      root.phase += Math.min(dt, 0.1)   // real time, not an assumed 1/60
    }
  }

  readonly property real laneMax: Math.max(level[0], Math.max(level[1],
                                     Math.max(level[2], level[3] || 0)))
  readonly property bool busy: laneMax > 0.04

  function countOf(id) { return (root.state.sources && root.state.sources[id]) || 0 }

  function tooltip() {
    // Everything installed, not just the four that fit on the sprite.
    var all = (root.state.agents || []).filter(function (a) { return a.watched })
    all.sort(function (a, b) {
      var ab = a.busy ? 1 : 0, bb = b.busy ? 1 : 0
      if (ab !== bb) return bb - ab
      return (b.last || 0) - (a.last || 0)
    })
    if (!all.length) all = (root.state.agents || []).slice(0, 3)
    var parts = []
    for (var i = 0; i < all.length; i++) {
      var a = all[i]
      parts.push((a.busy ? "● " : (a.watched ? "○ " : "· ")) + a.label + "  " + a.count)
    }
    parts.push("")
    parts.push("click to toggle the orb")
    return parts.join("\n")
  }

  // ------------------------------------------------------------ the widget
  // As square as the bar allows. The bar is 26px tall and every other widget
  // claims the full height, so take all of it bar a margin — at 21px the sprite
  // had too few pixels across for the bumps to read as anything but dither.
  implicitWidth: Math.max(17, Math.round(Style.bar.sizeHorizontal) - 3)
  implicitHeight: implicitWidth

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.busy
    activeColor: Color.accent
    tooltipText: root.tooltip()
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.broadcast("reload")
      else if (root.bar) root.bar.run("omarchy-shell shell toggle " + root.orbId + " '{}'")
    }
    iconComponent: Component {
      Canvas {
        id: sprite
        // Odd dimensions keep a pixel on the exact centre line.
        width: root.implicitWidth % 2 === 0 ? root.implicitWidth - 1 : root.implicitWidth
        height: width
        renderStrategy: Canvas.Immediate

        // The sprite lives inside a Component, so the frame timer cannot reach
        // it by id. It repaints off the clock instead.
        Connections {
          target: root
          function onPhaseChanged() { sprite.requestPaint() }
        }

        // 4x4 ordered dither. Cheaper than a random matrix and the fixed
        // pattern is what makes the shading read as deliberate pixel art
        // instead of noise.
        readonly property var bayer: [
          0, 8, 2, 10,
          12, 4, 14, 6,
          3, 11, 1, 9,
          15, 7, 13, 5
        ]

        function h3(x, y, z) {
          var n = Math.sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453
          return n - Math.floor(n)
        }
        function noise3(x, y, z) {
          var ix = Math.floor(x), iy = Math.floor(y), iz = Math.floor(z)
          var fx = x - ix, fy = y - iy, fz = z - iz
          var ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy), uz = fz * fz * (3 - 2 * fz)
          var s = 0
          for (var dz = 0; dz < 2; dz++)
            for (var dy = 0; dy < 2; dy++)
              for (var dx = 0; dx < 2; dx++) {
                var w = h3(ix + dx, iy + dy, iz + dz)
                s += w * (dx ? ux : 1 - ux) * (dy ? uy : 1 - uy) * (dz ? uz : 1 - uz)
              }
          return s
        }
        // Same value noise the floating orb displaces with, so the two move
        // with the same character.
        function snoise(x, y, z) {
          return (noise3(x, y, z) * 2.0 - 1.0) +
                 (noise3(x * 2.03, y * 2.03, z * 2.03) * 2.0 - 1.0) * 0.5
        }

        // Colour buckets are precomputed once per frame rather than looked up per
        // pixel: a bucket id packs both axes as shadeLevel * 4 + hueIndex, and
        // building the 4 x levels strings up front means no index arithmetic can
        // escape the array at paint time.
        function buildBuckets() {
          var hues = [root.hueA, root.hueB, root.hueC, root.hueD]
          var shades = Math.max(2, Math.round(root.levels))
          var out = new Array(4 * shades)
          for (var s = 0; s < shades; s++) {
            var t = s / (shades - 1)
            for (var h = 0; h < 4; h++) {
              var c = hues[h]
              out[s * 4 + h] = "rgb(" + Math.round(c.r * 255 * t) + "," +
                                Math.round(c.g * 255 * t) + "," +
                                Math.round(c.b * 255 * t) + ")"
            }
          }
          return out
        }

        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)

          var S = Math.min(width, height)
          var cxy = (S - 1) / 2 + 0.5
          var R = S * 0.5 - 1.5                     // leave room for the outline
          var lx = 0.35, ly = 0.55, lz = 2.0        // same key light as the orb
          var ll = Math.sqrt(lx * lx + ly * ly + lz * lz)
          lx /= ll; ly /= ll; lz /= ll
          var t = root.phase

          // 4 hues x N shade levels. Painting a bucket as one path of 1x1 rects
          // turns every pixel into about 20 draw calls.
          var buckets = buildBuckets()
          var runs = []

          // Everything that moves is gated on root.motion, which only rises while an
          // agent is actively writing. Idle is genuinely still: at this size a
          // constant idle drift reads as a dead pixel, and gating on the long
          // glow tail instead made it spin for six seconds after every message.
          var work = root.motion

          // Tumble: rotate the direction we sample the noise field in. Rotating
          // around z makes lumps travel sideways, around x tips the sphere, so
          // the pair reads as a rolling ball rather than a sliding texture.
          var spinA = t * (0.10 + 2.0 * work)
          var ca = Math.cos(spinA), sa = Math.sin(spinA)
          var tipB = t * (0.07 + 1.2 * work)
          var cb2 = Math.cos(tipB), sb2 = Math.sin(tipB)

          // A bright band travelling up the face, like a scanline. At this size
          // it is the single most legible thing on the sprite.
          var sweepPos = -1.2 + ((t * (0.55 + 1.7 * work)) % 2.4)

          for (var y = 0; y < S; y++) {
            for (var x = 0; x < S; x++) {
              var breathe = 1 + work * 0.05 * Math.sin(t * 2.6)
              var nx = (x + 0.5 - cxy) / (R * breathe)
              var ny = (y + 0.5 - cxy) / (R * breathe)
              var r2 = nx * nx + ny * ny
              var r = Math.sqrt(r2)
              if (r > 1.16) continue

              // Which agent owns this row of the sphere.
              var bandF = (ny + 1) / 2
              var band = Math.min(root.maxBands - 1,
                                  Math.floor(bandF * root.maxBands))
              var lv = root.level[band]

              // Displacement along the view ray's direction, same noise the
              // orb uses: slow and low at rest, swelling in an active band.
              var inv = r > 0 ? 1 / r : 0
              var dx = nx * inv, dy = ny * inv, dz = Math.sqrt(r2 > 1 ? 0 : 1 - r2)
              var rx = dx * ca - dy * sa
              var ry = dx * sa + dy * ca
              var ry2 = ry * cb2 - dz * sb2
              var rz2 = ry * sb2 + dz * cb2
              var amp = 0.05 + 0.30 * lv + 0.018 * Math.sin(t * 1.1 + band * 2.1)
              var d = snoise(rx * 2.2, ry2 * 2.2, rz2 * 2.2 + t * 0.45) * amp

              if (r > 1 + d) {
                // Just outside the surface: the sprite outline that gives a
                // pixel orb its edge. It brightens with the band, so a busy
                // third of the sphere reads as a lit bulge in the silhouette.
                var edge = r < 1 + d + 0.13 && r < 1.16
                if (!edge) continue
                var eShade = Math.max(0, 1 - (r - 1 - d) / 0.13) * (0.20 + 0.60 * lv)
                var eT = Math.floor(Math.min(1, eShade) * (root.levels - 1) +
                                    bayer[(y % 4) * 4 + (x % 4)] / 16)
                runs.push({ b: eT, x: x, y: y })
                continue
              }

              // Inside: light it like the orb (ambient + lambert + fresnel^2),
              // then dither the result down to `levels` steps.
              var nz = dz
              var ndl = Math.max(0, nx * lx + ny * ly + nz * lz)
              var fres = Math.pow(1 - nz, 3) * 0.55
              var lit = 0.22 + 0.78 * ndl + fres
              lit *= 0.70 + 0.80 * lv + 0.06 * Math.sin(t * 0.9 + band)
              lit += work * 0.5 * Math.exp(-Math.pow((ny - sweepPos) / 0.35, 2))
              var q = Math.floor(lit * (root.levels - 1) +
                                 bayer[(y % 4) * 4 + (x % 4)] / 16)

              // Hard-pick the nearest of the four anchors instead of blending:
              // flat regions of colour are what sell the sprite look.
              var ang = Math.atan2(ny, nx)
              var hue = Math.floor(((ang + Math.PI) / (2 * Math.PI)) * 4) % 4
              runs.push({ b: Math.max(0, Math.min(root.levels - 1, q)) * 4 + hue, x: x, y: y })
            }
          }

          // Fold the flat list into one path per bucket.
          var paths = {}
          for (var i = 0; i < runs.length; i++) {
            var p = runs[i]
            var key = "" + p.b
            if (!paths[key]) paths[key] = []
            paths[key].push(p.x, p.y)
          }
          for (var key2 in paths) {
            var pts = paths[key2]
            var b = Number(key2)
            ctx.fillStyle = buckets[b >= 0 && b < buckets.length ? b : 0]
            ctx.beginPath()
            for (var j = 0; j < pts.length; j += 2) ctx.rect(pts[j], pts[j + 1], 1, 1)
            ctx.fill()
          }
        }
      }
    }
  }
}