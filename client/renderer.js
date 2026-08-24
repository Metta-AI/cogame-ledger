// Ledger shared renderer + drivers.
//
// This file is cogame-babel's client/renderer.js. Ledger's edits are the SCENE
// (computeLayout and draw are the plaza instead of babel's two speaker/listener
// booths; babel's sceneOf/sceneText/boothPairs/pendingSeat/drawSeat/drawCard/
// drawShape/drawRibbon/spellTokens are replaced by the plaza helpers below) and
// the EVENT VOCABULARY: describeEvent, endText, phaseText, matchHeader,
// updateScorebug, updateEndscreen, buildScrub's marker classes, renderFeed's
// new lines, makeEffects's timers, stateToView's fields, and the two drivers'
// calls know Ledger's five event kinds and its gossip/rings state.
// Byte-identical babel code: makeRenderer, loadImages, assetUrl, ellipsize,
// hexToRgb/shade/rgba, roundRect, drawTag, seatColor, makeNameMap, applyNames,
// clampName, isBaselineFiller, roundBase, blockHead, escapeHtml, reasonLine.
// The full function-by-function list is in
// docs/plans/2026-08-23-ledger-design.md, "Chrome provenance", and the
// board-first revision of the scene is the section under it.
//
// THE SCENE, board-first revision (2026-08-23)
// --------------------------------------------
// One canvas scene fed by three drivers: live /global websocket, live /player
// websocket, and replay (from the game's /replay websocket or the static wasm
// bundle). An octagonal plaza holds eight POSTS, and this round's four
// MEETINGS are drawn as lines between the posts that are playing them:
//
//   post     reputation gauge (an arc you can read a value off), the sprite
//            inside it, a seat-coloured ground ellipse, and ONE alias plate
//            placed radially outward carrying the alias and the median.
//   meeting  a lit line between the two cogs, with a plaque on a leader off
//            that line: the subgame in words, both committed moves, both
//            payoffs, and the verdict icon.
//   thread   a red dashed curve between a flagged pair, tagged FLAGGED at the
//            curve's midpoint. Rings of three or more are named in the
//            findings panel.
//
// What this revision removed, and why (each was a measured failure of the
// first build, not a matter of taste):
//   - the per-seat memo parchment. Eight bright #f2e8d8 cards of body copy
//     were the highest-contrast objects on a dark stage and made the seat
//     block so tall that the ring could not be solved. The memos are in the
//     log, where they belong.
//   - the filled reputation halo. Its radius reached 0.8 of a cog on a ring
//     of 0.95, so the eight glows merged into fog and no value could be read
//     off one. It is an arc now.
//   - `ring = Math.max(size * 0.95, ring)`. The old solver gave up and
//     collapsed the RING when a frame got tight, which is what put eight seat
//     blocks on top of each other. The ring is the invariant now (MIN_RING)
//     and the cog shrinks until it holds.
//   - the four inner-ring tables, the 0.42 slide toward them, the role tag
//     over each cog, and the alias/median drawn under every cog AND again in
//     the plate row.
//
// All state derivation happens server-side / wasm-side; this file only draws
// state objects:
//   {seats:[{name,score,mean,total,meetings,kind,harsh,halo,partner,game,
//            role,move,lastPay,memo,scripted} ×8],
//    round, rounds, roundsPlayed,
//    pairs:[{a,b,game,first,moveA,moveB,payA,payB,resolved} ×4],
//    gossip:[{round,author,subject,text}], rings:[{a,b,delta}],
//    phase:"deal|resolve|between|done", gameDone, reason}
// The plaza is a FIXED arena that always fits the frame, so there is no zoom
// bar and no minimap.
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Ledger
  // seats EIGHT cogs, so the four sprite kits are each used twice and an
  // eight-entry palette (plus the alias plate and the halo) is what tells
  // them apart; the seatN classes keep lining up with the CSS.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange",
    "teal", "rose"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a",
    teal: "#3fb0a8",
    rose: "#d9628f"
  };
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var PAPER_DIM = "#b8ac98";
  var GHOST = "#8a7f72";
  var CARD_EDGE = "rgba(42, 31, 22, 0.85)";
  var STRIP = "rgba(242, 232, 216, 0.06)";
  // The resolution icon (handshake, knife, crossed knives, snapped coin)
  // holds for a beat, then fades to a resting tint so a paused frame still
  // reads.
  var MEET_HOLD_MS = 1200;
  var MEET_FADE_MS = 700;
  var MEET_REST = 0.35;
  var SLIDE_MS = 520;
  var COIN_MS = 1100;

  // Symbols fall through to a system symbol font when rajdhani lacks them.
  var GLYPH_FONT = "'rajdhani', 'Apple Symbols', 'Segoe UI Symbol', " +
    "'Noto Sans Symbols 2', system-ui, sans-serif";

  // Four sprite kits over eight seats; the palette, the plate and the halo
  // disambiguate the two seats that share a kit.
  var SPRITE_KITS = ["red", "blue", "green", "yellow"];

  // Words, never notation: a spectator reads DILEMMA, not "pd".
  var GAME_NAMES = { pd: "DILEMMA", trust: "TRUST", ultimatum: "ULTIMATUM" };
  var ROLE_NAMES = {
    pd: ["EITHER", "EITHER"],
    trust: ["INVESTOR", "TRUSTEE"],
    ultimatum: ["PROPOSER", "RESPONDER"]
  };

  function gameName(id) {
    return GAME_NAMES[id] || String(id || "").toUpperCase();
  }

  function roleName(id, first) {
    var pair = ROLE_NAMES[id];
    return pair ? pair[first ? 0 : 1] : "";
  }

  // How a raw move reads in a feed line or on a table tag.
  function moveText(id, first, move) {
    if (move === null || move === undefined) return "";
    if (id === "pd") return move === 0 ? "cooperate" : "defect";
    if (id === "trust") {
      return first ? "sent " + move : "returned " + move + "%";
    }
    return first ? "offered " + move : "floor " + move;
  }

  // Conduct, on exactly the thresholds the sim applies.
  function isKind(id, first, move) {
    if (move === null || move === undefined) return true;
    if (id === "pd") return move === 0;
    if (id === "trust") return first ? move >= 3 : move >= 50;
    return first ? move >= 5 : move <= 5;
  }

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  // Colour helpers for the shape rims / highlights.
  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  // Nominal cog size; everything around a cog is measured as a multiple of
  // it so the whole seat post scales as one unit.
  var SEAT_BASE = 84;
  // A post is the reputation gauge, the sprite inside it, and one alias plate
  // placed radially outward. That is ALL a post carries: the memo parchment
  // that used to hang under every cog is gone from the canvas (it was the
  // highest-contrast object on a dark stage, eight times over, and it made
  // the seat block so tall the ring could not be solved).
  var GAUGE_R = 0.62;         // gauge radius, in cogs
  var PLATE_GAP = 0.11;       // gauge edge -> alias plate, in cogs
  var PLATE_H = 0.20;         // alias plate line height, in cogs
  var PLATE_W = 1.45;         // alias plate width budget, in cogs
  // The ring is the INVARIANT and the cog shrinks until it holds. The old
  // solver had it the other way round: when the frame got tight it collapsed
  // the ring (`ring = Math.max(size * 0.95, ring)`) and left eight seat
  // blocks overlapping, which is the single reason the board was unreadable.
  //
  // 2.6 cogs is the larger of the two floors this scene needs:
  //   posts:   two adjacent gauges clear each other above
  //            (2 * GAUGE_R) / (2 * sin(pi/8)) = 1.62 cogs;
  //   plaques: a quadrant plaque (half-diagonal ~1.07 cogs) clears the
  //            diagonal post above ~2.4 cogs.
  var MIN_RING = 2.6;
  // How far the plaza may stretch across a wide frame.
  var ECCENTRIC = 1.4;

  // The meeting plaque: the round's four meetings, each drawn ON the line
  // between the two cogs that are playing it.
  var PLAQUE_W = 2.1, PLAQUE_H = 0.88;

  // ---- The plaza -----------------------------------------------------------

  // How far a post reaches beyond its own centre, outward along the radius.
  // The alias plate is placed radially, so the reach is the same in every
  // direction except that a sideways plate spends its budget on width.
  function postReach(size, sideways) {
    var scale = size / SEAT_BASE;
    var gauge = size * GAUGE_R;
    return sideways ?
      gauge + size * PLATE_GAP + size * PLATE_W :
      gauge + size * PLATE_GAP + size * PLATE_H * 2;
  }

  function computeLayout(width, height) {
    // Solved per frame, and solved the right way round: the ring never
    // collapses into the posts, the cog shrinks until the ring, the posts and
    // the margins all fit. Callers embed this viewer at wildly different
    // sizes (the softmax.com featured match is ~360 px wide), so the only
    // thing held fixed is that two posts never touch.
    var margin = Math.max(6, Math.min(width, height) * 0.025);
    var size = Math.min(SEAT_BASE, Math.min(width, height) * 0.165);
    var ring = 0;
    var horizontal = 0;
    var vertical = 0;
    for (var attempt = 0; attempt < 60; attempt++) {
      vertical = (height - 2 * margin) / 2 - postReach(size, false);
      horizontal = (width - 2 * margin) / 2 - postReach(size, true);
      ring = Math.min(vertical, horizontal);
      if (ring >= size * MIN_RING || size <= 18) break;
      size *= 0.94;
    }
    size = Math.max(18, size);
    ring = Math.max(size * MIN_RING, ring);
    // A replay pane is rarely square -- a desktop replay is about 2:1 and
    // the featured-match iframe is taller than it is wide -- and a circular
    // plaza in either leaves half the board empty. Stretch the ring into
    // whatever space is spare on each axis, up to ECCENTRIC. Stretching
    // along one axis only ever WIDENS every adjacent-post gap, so the
    // clearance the ring floor buys survives it.
    var ringX = Math.max(ring, Math.min(horizontal, ring * ECCENTRIC));
    var ringY = Math.max(ring, Math.min(vertical, ring * ECCENTRIC));
    return {
      cx: width / 2,
      cy: height / 2,
      span: Math.min(width, height),
      ring: ring,
      ringX: ringX,
      ringY: ringY,
      size: size,
      scale: size / SEAT_BASE,
      width: width,
      height: height
    };
  }

  function seatAngle(index) {
    return -Math.PI / 2 + index * Math.PI / 4;
  }

  function seatHome(layout, index) {
    var a = seatAngle(index);
    return {
      x: layout.cx + Math.cos(a) * layout.ringX,
      y: layout.cy + Math.sin(a) * layout.ringY
    };
  }

  // Where a meeting's plaque goes. The four plaques take the four quadrants
  // of the plaza -- one per quadrant, each assigned to the meeting whose line
  // passes nearest it -- and a leader ties each plaque back to a point on its
  // own line. Two meeting lines that cross (opposite seats always do) then
  // never contend for the same spot, which is what happened when the plaque
  // sat at the midpoint of its chord.
  // The plaque box, sized to the RING rather than to the cog: in a frame too
  // tight to hold four full plaques the plaque shrinks (and its type with
  // it) instead of piling onto the posts.
  function plaqueBox(layout) {
    var w = Math.min(layout.size * PLAQUE_W, layout.ringY * 0.72);
    return {
      w: w,
      h: w * (PLAQUE_H / PLAQUE_W),
      scale: w / (SEAT_BASE * PLAQUE_W)
    };
  }

  // Where a meeting's plaque goes. The four plaques sit on the AXES -- above,
  // below, left and right of the plaza centre -- one per meeting, each
  // assigned to the meeting whose line passes nearest it, with a leader back
  // to a point on that line. Off the axes they would sit on the same bearing
  // as the diagonal posts, which is what a plaque at its own chord midpoint
  // did: land exactly where two meeting lines cross.
  function plaqueSpots(layout, pairs, seatSpots) {
    // Pushed as far out along each axis as the box will go without reaching
    // the post at the end of it, so the four plaques spread rather than
    // clustering in the middle of the plaza.
    var box = plaqueBox(layout);
    var pad = layout.size * 0.7;
    var qx = Math.min(layout.ringX * 0.52,
      layout.ringX - box.w / 2 - pad);
    var qy = Math.min(layout.ringY * 0.50,
      layout.ringY - box.h / 2 - pad);
    var slots = [
      { x: layout.cx, y: layout.cy - qy },
      { x: layout.cx + qx, y: layout.cy },
      { x: layout.cx, y: layout.cy + qy },
      { x: layout.cx - qx, y: layout.cy }
    ];
    // Greedy nearest-slot assignment: the shortest plaque-to-slot distance
    // wins its slot first, so the arrangement is stable frame to frame rather
    // than reshuffling whenever the pair order changes.
    var wants = [];
    pairs.forEach(function (pair, index) {
      var a = seatSpots[pair.a];
      var b = seatSpots[pair.b];
      if (!a || !b) return;
      var mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      slots.forEach(function (slot, si) {
        wants.push({
          pair: index,
          slot: si,
          d: Math.hypot(slot.x - mid.x, slot.y - mid.y)
        });
      });
    });
    wants.sort(function (l, r) { return l.d - r.d; });
    var takenPair = {}, takenSlot = {}, out = [];
    wants.forEach(function (want) {
      if (takenPair[want.pair] || takenSlot[want.slot]) return;
      takenPair[want.pair] = true;
      takenSlot[want.slot] = true;
      out[want.pair] = nudgeClear(layout, slots[want.slot], seatSpots);
    });
    return out;
  }

  // Pull a plaque toward the plaza centre until its box clears every cog. The
  // axis slots clear them already at every ring this layout produces; this is
  // the guard for the frames where they do not.
  function nudgeClear(layout, slot, seatSpots) {
    var box = plaqueBox(layout);
    var hw = box.w / 2;
    var hh = box.h / 2;
    var cog = layout.size * 0.6;
    var spot = { x: slot.x, y: slot.y };
    for (var step = 0; step < 12; step++) {
      var clear = true;
      for (var seat = 0; seat < seatSpots.length; seat++) {
        var p = seatSpots[seat];
        if (!p) continue;
        var dx = Math.max(Math.abs(p.x - spot.x) - hw, 0);
        var dy = Math.max(Math.abs(p.y - spot.y) - hh, 0);
        if (dx * dx + dy * dy < cog * cog) { clear = false; break; }
      }
      if (clear) break;
      spot.x += (layout.cx - spot.x) * 0.1;
      spot.y += (layout.cy - spot.y) * 0.1;
    }
    return spot;
  }

  // The point on a meeting's line that its plaque's leader attaches to: the
  // closest point on the segment, so the leader is always the short way home.
  function leaderFoot(from, to, spot) {
    var dx = to.x - from.x;
    var dy = to.y - from.y;
    var len2 = dx * dx + dy * dy;
    if (len2 < 1) return { x: from.x, y: from.y };
    var t = ((spot.x - from.x) * dx + (spot.y - from.y) * dy) / len2;
    t = Math.max(0.18, Math.min(0.82, t));
    return { x: from.x + dx * t, y: from.y + dy * t };
  }

  // Shorten a meeting line at both ends so it starts outside the gauges.
  function trimSegment(from, to, back) {
    var dx = to.x - from.x;
    var dy = to.y - from.y;
    var len = Math.hypot(dx, dy) || 1;
    var ux = dx / len, uy = dy / len;
    return [
      { x: from.x + ux * back, y: from.y + uy * back },
      { x: to.x - ux * back, y: to.y - uy * back }
    ];
  }

  // Which seats sit at which table: the state's pairs when it has them (live
  // global / replay), else the resting arrangement so a redacted player frame
  // still shows eight cogs around four dark tables.
  function plazaPairs(view) {
    var pairs = view.pairs || [];
    if (pairs.length >= 4) return pairs;
    var rest = [{ a: 0, b: 1 }, { a: 2, b: 3 }, { a: 4, b: 5 },
      { a: 6, b: 7 }];
    return rest.map(function (p, i) { return pairs[i] || p; });
  }

  function eased(t) {
    return 1 - Math.pow(1 - Math.max(0, Math.min(1, t)), 3);
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var layout = computeLayout(w, h);
    var scale = layout.scale;
    var size = layout.size;
    var fx = view.effects || { roundAt: null, meetAt: [], gossipAt: null };
    var pairs = plazaPairs(view);
    var live = view.phase === "deal" || view.phase === "resolve";

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    // The plaza itself: an octagon of flagstones under everything.
    drawPlaza(ctx, layout);

    // Posts do not move any more. The old build slid a paired cog 42% of the
    // way to its table, which read as jitter rather than as a pairing; the
    // pairing is now the LINE, which says it outright.
    var spots = [];
    for (var s = 0; s < 8; s++) spots.push(seatHome(layout, s));
    var plaques = plaqueSpots(layout, pairs, spots);

    // Red threads first, UNDER everything: the cartel is a picture.
    drawThreads(ctx, layout, view.rings || [], spots, scale);

    // This round's four meetings, each drawn as a lit line between the two
    // cogs playing it, with the plaque on a leader off that line.
    pairs.forEach(function (pair, pi) {
      var from = spots[pair.a];
      var to = spots[pair.b];
      var spot = plaques[pi];
      if (!from || !to || !spot) return;
      if (pair.game === undefined || pair.game === null) return;
      drawMeetingLine(ctx, from, to, spot, layout, live);
    });
    // Posts: gauge, sprite, seat-coloured ground, alias plate.
    for (var i = 0; i < 8; i++) {
      drawAvatar(ctx, images, seats[i], i, spots[i], size, scale, layout, {
        deciding: view.phase === "deal",
        done: !!view.done
      });
    }

    // Plaques last, over the posts: the meeting is the loudest thing here.
    var box = plaqueBox(layout);
    pairs.forEach(function (pair, pi) {
      var spot = plaques[pi];
      if (!spot || pair.game === undefined || pair.game === null) return;
      var meetAt = fx.meetAt && fx.meetAt[pi];
      var age = typeof meetAt === "number" ? now - meetAt : null;
      var alpha = age === null ? MEET_REST :
        age < MEET_HOLD_MS ? 1 :
        Math.max(MEET_REST, 1 - (age - MEET_HOLD_MS) / MEET_FADE_MS *
          (1 - MEET_REST));
      drawPlaque(ctx, spot, pair, box, live, pair.resolved ? alpha : 0,
        seats);
      if (pair.resolved) drawCoins(ctx, spot, pair, spots, scale, age);
    });

    syncRail(view);
  }

  function drawPlaza(ctx, layout) {
    var rx = layout.ringX * 1.22;
    var ry = layout.ringY * 1.22;
    ctx.save();
    ctx.beginPath();
    for (var i = 0; i < 8; i++) {
      var a = -Math.PI / 2 + (i + 0.5) * Math.PI / 4;
      var x = layout.cx + Math.cos(a) * rx;
      var y = layout.cy + Math.sin(a) * ry;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.closePath();
    ctx.fillStyle = STRIP;
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.14)";
    ctx.lineWidth = 1.5;
    ctx.stroke();
    ctx.restore();
  }

  // A meeting, drawn as a LINE between the two cogs playing it: a dark plank
  // with a lit core, plus the leader that ties the plaque back to the line.
  // This is the fact the old board never drew -- who is playing whom.
  function drawMeetingLine(ctx, from, to, spot, layout, lit) {
    var back = layout.size * GAUGE_R + layout.size * 0.07;
    var ends = trimSegment(from, to, back);
    ctx.save();
    ctx.lineCap = "round";
    ctx.strokeStyle = "rgba(242, 232, 216, 0.12)";
    ctx.lineWidth = Math.max(3, layout.size * 0.105);
    ctx.beginPath();
    ctx.moveTo(ends[0].x, ends[0].y);
    ctx.lineTo(ends[1].x, ends[1].y);
    ctx.stroke();
    ctx.lineCap = "butt";
    ctx.strokeStyle = lit ? rgba(AMBER, 0.62) : "rgba(242, 232, 216, 0.16)";
    ctx.lineWidth = Math.max(1, layout.scale * 2);
    ctx.beginPath();
    ctx.moveTo(ends[0].x, ends[0].y);
    ctx.lineTo(ends[1].x, ends[1].y);
    ctx.stroke();
    // Leader from the plaque to its own line, with a dot where it lands.
    var foot = leaderFoot(ends[0], ends[1], spot);
    ctx.strokeStyle = rgba(AMBER, 0.45);
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(foot.x, foot.y);
    ctx.lineTo(spot.x, spot.y);
    ctx.stroke();
    ctx.fillStyle = rgba(AMBER, 0.8);
    ctx.beginPath();
    ctx.arc(foot.x, foot.y, Math.max(1.5, 2.5 * layout.scale), 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }

  // The plaque: the subgame in WORDS, both committed moves and both payoffs,
  // one row per seat in that seat's colour. The verdict icon sits in the
  // header. This is now the largest type on the board, which is the point --
  // the meeting is the only thing actually happening.
  function drawPlaque(ctx, spot, pair, box, lit, verdictAlpha, seats) {
    var w = box.w;
    var h = box.h;
    var scale = box.scale;
    var x = spot.x - w / 2;
    var y = spot.y - h / 2;
    var pad = Math.max(4, 8 * scale);
    ctx.save();
    ctx.fillStyle = lit ? "rgba(36, 26, 18, 0.94)" : "rgba(18, 13, 9, 0.8)";
    ctx.strokeStyle = lit ? rgba(AMBER, 0.55) : "rgba(242, 232, 216, 0.14)";
    ctx.lineWidth = lit ? 2 : 1;
    roundRect(ctx, x, y, w, h, 5 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.textBaseline = "middle";

    var headY = y + h * 0.21;
    ctx.textAlign = "left";
    ctx.font = "700 " + Math.max(9, Math.round(11 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.fillText(ellipsize(ctx, gameName(pair.game), w - pad * 2 - 24 * scale),
      x + pad, headY);
    if (pair.resolved) {
      drawVerdict(ctx, x + w - pad - 10 * scale, headY, pair,
        Math.max(7, 10 * scale), verdictAlpha);
    }

    // One row per seat: alias, the move in words, the payoff in coins.
    // Before a seat's move is known the row carries its ROLE instead, so a
    // table that is still deciding says what it is rather than going blank.
    var rows = [
      [pair.a, moveText(pair.game, true, pair.moveA) ||
        pendingText(pair.game, true), pair.payA],
      [pair.b, moveText(pair.game, false, pair.moveB) ||
        pendingText(pair.game, false), pair.payB]
    ];
    var broken = isBroken(pair);
    rows.forEach(function (row, index) {
      var ry = y + h * (0.52 + index * 0.29);
      var nameW = w * 0.42;
      ctx.textAlign = "left";
      ctx.font = "600 " + Math.max(9, Math.round(12 * scale)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = COLOR_HEX[seatColor(row[0])];
      var seat = (seats || [])[row[0]] || {};
      var alias = ellipsize(ctx, clampName(seat.name || ""), nameW);
      ctx.fillText(alias, x + pad, ry);
      var moveX = x + pad + ctx.measureText(alias).width + 6 * scale;
      ctx.font = Math.max(8, Math.round(11 * scale)) +
        "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
      ctx.fillStyle = GHOST;
      var payText = typeof row[2] === "number" ?
        (broken ? "0" : "+" + row[2]) : "";
      ctx.textAlign = "right";
      var payW = 0;
      if (payText) {
        ctx.save();
        ctx.font = "700 " + Math.max(9, Math.round(13 * scale)) +
          "px 'rajdhani', system-ui, sans-serif";
        payW = ctx.measureText(payText).width + 8 * scale;
        ctx.fillStyle = broken || row[2] === 0 ? GHOST : AMBER;
        ctx.fillText(payText, x + w - pad, ry);
        ctx.restore();
      }
      ctx.textAlign = "left";
      ctx.fillStyle = PAPER_DIM;
      ctx.fillText(ellipsize(ctx, row[1], x + w - pad - payW - moveX), moveX,
        ry);
    });
    ctx.restore();
  }

  // What a row says before its move is known. TRUST and ULTIMATUM are
  // asymmetric, so the role is worth saying; the dilemma has no role (both
  // seats choose the same two moves), and "EITHER" said nothing.
  function pendingText(game, first) {
    return game === "pd" ? "deciding" : roleName(game, first);
  }

  // A rejected ultimatum: both sides take nothing.
  function isBroken(pair) {
    return pair.game === "ultimatum" && pair.payA === 0 && pair.payB === 0;
  }

  // Both kind: a handshake. One harsh: a knife. Both harsh: crossed knives.
  // A rejected ultimatum: a snapped coin. Same four shapes as before, drawn
  // in the plaque header instead of floating over a table.
  function drawVerdict(ctx, cx, cy, pair, r, alpha) {
    var kindA = isKind(pair.game, true, pair.moveA);
    var kindB = isKind(pair.game, false, pair.moveB);
    ctx.save();
    ctx.globalAlpha = Math.max(MEET_REST, alpha);
    if (isBroken(pair)) {
      drawSnappedCoin(ctx, cx, cy, r);
    } else if (kindA && kindB) {
      drawHandshake(ctx, cx, cy, r);
    } else if (!kindA && !kindB) {
      drawKnife(ctx, cx - r * 0.45, cy, r, -0.5);
      drawKnife(ctx, cx + r * 0.45, cy, r, 0.5);
    } else {
      drawKnife(ctx, cx, cy, r, kindB ? -0.35 : 0.35);
    }
    ctx.restore();
  }

  function drawHandshake(ctx, cx, cy, r) {
    ctx.save();
    ctx.strokeStyle = COLOR_HEX.green;
    ctx.lineWidth = Math.max(2, r * 0.24);
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.beginPath();
    ctx.moveTo(cx - r, cy - r * 0.35);
    ctx.lineTo(cx - r * 0.15, cy + r * 0.1);
    ctx.lineTo(cx + r * 0.15, cy - r * 0.1);
    ctx.lineTo(cx + r, cy + r * 0.35);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(cx, cy, r * 0.28, 0, Math.PI * 2);
    ctx.fillStyle = rgba(COLOR_HEX.green, 0.9);
    ctx.fill();
    ctx.restore();
  }

  function drawKnife(ctx, cx, cy, r, tilt) {
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(tilt);
    ctx.fillStyle = COLOR_HEX.red;
    ctx.beginPath();
    ctx.moveTo(0, -r);
    ctx.lineTo(r * 0.28, -r * 0.1);
    ctx.lineTo(0, r * 0.15);
    ctx.lineTo(-r * 0.28, -r * 0.1);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = shade(COLOR_HEX.red, 0.5);
    roundRect(ctx, -r * 0.12, r * 0.15, r * 0.24, r * 0.7, r * 0.08);
    ctx.fill();
    ctx.restore();
  }

  function drawSnappedCoin(ctx, cx, cy, r) {
    ctx.save();
    ctx.strokeStyle = GHOST;
    ctx.fillStyle = "rgba(138, 127, 114, 0.35)";
    ctx.lineWidth = Math.max(1.5, r * 0.16);
    [-1, 1].forEach(function (side) {
      ctx.beginPath();
      ctx.arc(cx + side * r * 0.28, cy, r * 0.6, side < 0 ?
        Math.PI * 0.5 : Math.PI * 1.5, side < 0 ?
        Math.PI * 1.5 : Math.PI * 0.5);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
    });
    ctx.restore();
  }

  // Coins fly from the table to each avatar with a +N in the seat colour.
  function drawCoins(ctx, spot, pair, spots, scale, age) {
    var t = age === null ? 1 : eased(age / COIN_MS);
    [[pair.a, pair.payA], [pair.b, pair.payB]].forEach(function (entry) {
      var seat = entry[0];
      var pay = entry[1];
      if (typeof seat !== "number" || typeof pay !== "number") return;
      var target = spots[seat];
      if (!target) return;
      var x = spot.x + (target.x - spot.x) * t;
      var y = spot.y + (target.y - spot.y) * t - 22 * scale * Math.sin(t * Math.PI);
      ctx.save();
      ctx.globalAlpha = pay > 0 ? 1 : 0.5;
      ctx.font = "700 " + Math.max(10, Math.round(13 * scale)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillStyle = pay > 0 ? COLOR_HEX[seatColor(seat)] : GHOST;
      ctx.shadowColor = "rgba(0,0,0,0.85)";
      ctx.shadowBlur = 4;
      ctx.fillText("+" + pay, x, y);
      ctx.restore();
    });
  }

  // Red threads between flagged pairs, drawn UNDER the avatars, thickness
  // 1 + delta/2, with a RING tag at the midpoint.
  function drawThreads(ctx, layout, rings, spots, scale) {
    rings.forEach(function (ring) {
      var from = spots[ring.a];
      var to = spots[ring.b];
      if (!from || !to) return;
      ctx.save();
      ctx.strokeStyle = rgba(COLOR_HEX.red, 0.75);
      ctx.lineWidth = 1 + (ring.delta || 0) / 2;
      ctx.setLineDash([7, 5]);
      ctx.beginPath();
      ctx.moveTo(from.x, from.y);
      ctx.quadraticCurveTo(layout.cx, layout.cy, to.x, to.y);
      ctx.stroke();
      ctx.restore();
      // On the CURVE, not the chord: the thread bows through the plaza
      // centre, so the chord midpoint is exactly where the meeting lines
      // cross. And a single flagged pair is a thread, not a cartel -- the
      // RING caption belongs to a component of three or more (ringGroups).
      drawTag(ctx, (from.x + 2 * layout.cx + to.x) / 4,
        (from.y + 2 * layout.cy + to.y) / 4, "FLAGGED", COLOR_HEX.red, scale);
    });
  }

  // A post: reputation gauge, sprite, seat-coloured ground, alias plate.
  // The memo parchment that used to hang under every cog is gone -- the
  // reasoning lives in the log, where it does not outshout the game.
  function drawAvatar(ctx, images, seat, index, pos, size, scale, layout,
                      opts) {
    if (!seat || !pos) return;
    var color = seatColor(index);
    var sprite = images["soldier_" + SPRITE_KITS[index % SPRITE_KITS.length] +
      "_front.png"];

    // The gauge FIRST, behind the cog: an arc you can read a value off,
    // where the old build drew a filled glow that merged with its neighbours
    // into fog.
    drawGauge(ctx, pos, size, typeof seat.halo === "number" ? seat.halo : 0.5,
      opts.deciding && !opts.done);

    ctx.save();
    ctx.translate(pos.x, pos.y);
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
    }
    // A seat-coloured ground ellipse under the wheels: the sprite kit repeats
    // every four seats, this never does.
    ctx.globalAlpha = 0.85;
    ctx.beginPath();
    ctx.ellipse(0, size * 0.46, size * 0.30, size * 0.10, 0, 0, Math.PI * 2);
    ctx.fillStyle = rgba(COLOR_HEX[color], 0.55);
    ctx.fill();
    ctx.strokeStyle = COLOR_HEX[color];
    ctx.lineWidth = 1.5;
    ctx.stroke();
    ctx.restore();

    drawAliasPlate(ctx, seat, index, pos, size, scale, layout);
  }

  // Alias and median on ONE baseline, placed radially outward from the plaza
  // centre and end-aligned. Radial placement is what lets eight plates fan
  // out instead of colliding at the sizes this viewer is embedded at; the
  // pair of them used to be drawn under the cog AND again in the plate row.
  function drawAliasPlate(ctx, seat, index, pos, size, scale, layout) {
    var a = seatAngle(index);
    var ux = Math.cos(a), uy = Math.sin(a);
    var sideways = Math.abs(ux) > 0.9;
    var reach = size * GAUGE_R + size * PLATE_GAP;
    var x = pos.x + ux * reach;
    var y = pos.y + uy * reach;
    var font = Math.max(10, Math.round(14 * scale));
    ctx.save();
    ctx.font = "600 " + font + "px 'rajdhani', system-ui, sans-serif";
    var alias = clampName(seat.name || "");
    var score = Number(seat.score || 0).toFixed(1);
    var gap = 6 * scale;
    ctx.font = "700 " + font + "px 'rajdhani', system-ui, sans-serif";
    var scoreW = ctx.measureText(score).width;
    ctx.font = "600 " + font + "px 'rajdhani', system-ui, sans-serif";
    alias = ellipsize(ctx, alias, size * PLATE_W - scoreW - gap);
    var aliasW = ctx.measureText(alias).width;
    var total = aliasW + gap + scoreW;

    // Anchor the pair as one run, then align it away from the plaza.
    var left;
    if (ux > 0.3) left = x;
    else if (ux < -0.3) left = x - total;
    else left = x - total / 2;
    if (Math.abs(uy) > 0.9) y += uy < 0 ? -font * 0.55 : font * 0.55;
    // Never let a plate run off the canvas: clamp, do not clip.
    left = Math.max(3, Math.min(layout.width - total - 3, left));

    ctx.textBaseline = "middle";
    ctx.textAlign = "left";
    ctx.shadowColor = "rgba(0,0,0,0.85)";
    ctx.shadowBlur = 4;
    ctx.fillStyle = COLOR_HEX[seatColor(index)];
    ctx.fillText(alias, left, y);
    ctx.font = "700 " + font + "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = AMBER;
    ctx.fillText(score, left + aliasW + gap, y);
    ctx.restore();
    void sideways;
  }

  // Reputation as a VALUE: an arc sweeping the seat's share of meetings
  // played fair, clockwise from the top. Gold above 0.7, pale above 0.4,
  // cold grey below -- the same thresholds the halo used, now readable.
  // The track is deliberately thinner and dimmer than the value, so a seat
  // with a bad record does not read as a full pale ring.
  function drawGauge(ctx, pos, size, halo, deciding) {
    var share = Math.max(0, Math.min(1, halo));
    var tint = share > 0.7 ? AMBER : share > 0.4 ? PAPER : GHOST;
    var r = size * GAUGE_R;
    var weight = Math.max(2, size * 0.045);
    ctx.save();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.09)";
    ctx.lineWidth = weight * 0.55;
    ctx.beginPath();
    ctx.arc(pos.x, pos.y, r, 0, Math.PI * 2);
    ctx.stroke();
    if (share > 0) {
      ctx.strokeStyle = tint;
      ctx.lineWidth = weight * 1.25;
      ctx.beginPath();
      ctx.arc(pos.x, pos.y, r, -Math.PI / 2,
        -Math.PI / 2 + share * Math.PI * 2);
      ctx.stroke();
    }
    // Everyone decides at the same time, so the "acting" marker is on all
    // eight seats while the round is open. It sits INSIDE the gauge; posts
    // are spaced to clear the gauge and nothing wider.
    if (deciding) {
      ctx.strokeStyle = rgba(AMBER, 0.55);
      ctx.lineWidth = 1.5;
      ctx.setLineDash([5, 5]);
      ctx.beginPath();
      ctx.arc(pos.x, pos.y, r - weight * 1.8, 0, Math.PI * 2);
      ctx.stroke();
      ctx.setLineDash([]);
    }
    ctx.restore();
  }

  // The gossip rail and the ring caption are DOM, inside #board-wrap and
  // therefore above the transport band, never in it. Being DOM is what lets
  // the 480 px media query collapse the rail so the tables stay readable.
  //
  // A RING is a connected component of size >= 3 in the flagged graph, the
  // same definition the sim applies in ringComponents (src/ledger/sim.nim
  // :437-463) — a single flagged pair is a thread, not a ring, and gets its
  // thread drawn and its feed line without a cartel caption.
  function ringGroups(rings) {
    var parent = {};
    function find(x) {
      while (parent[x] !== undefined && parent[x] !== x) x = parent[x];
      return x;
    }
    (rings || []).forEach(function (ring) {
      if (parent[ring.a] === undefined) parent[ring.a] = ring.a;
      if (parent[ring.b] === undefined) parent[ring.b] = ring.b;
      var ra = find(ring.a);
      var rb = find(ring.b);
      if (ra !== rb) parent[ra] = rb;
    });
    var groups = {};
    Object.keys(parent).forEach(function (key) {
      var root = find(Number(key));
      if (!groups[root]) groups[root] = [];
      groups[root].push(Number(key));
    });
    return Object.keys(groups).map(function (key) {
      return groups[key].sort(function (a, b) { return a - b; });
    }).filter(function (group) {
      return group.length >= 3;
    });
  }

  function syncRail(view) {
    var nameOf = view.nameOf || function (i) { return "Seat " + i; };
    var rail = document.getElementById("gossip-rail");
    if (rail) {
      var html = (view.gossip || []).slice(-5).map(function (note) {
        return '<div class="gossip-card"><div class="gossip-who">' +
          escapeHtml(clampName(nameOf(note.author)) + " on " +
            clampName(nameOf(note.subject))) + "</div>" +
          '<div class="gossip-text">' + escapeHtml(note.text || "") +
          "</div></div>";
      }).join("");
      if (rail.dataset.html !== html) {
        rail.dataset.html = html;
        rail.innerHTML = html;
      }
      rail.classList.toggle("show", html.length > 0);
    }
    // #ringnote is the FINDINGS panel: the legend for the one encoding a
    // spectator cannot guess (the gauge), plus every flagged pair and every
    // ring. It sits opposite the gossip rail instead of on top of the plaza,
    // which is where the rail used to be parked (top:10 right:10, straight
    // over the upper-right posts).
    var ringnote = document.getElementById("ringnote");
    if (!ringnote) return;
    var rings = view.rings || [];
    var findHtml = '<div class="find-legend">ring = share of meetings ' +
      "played fair</div>";
    if (rings.length) {
      findHtml += '<div class="find-title">FLAGGED</div>';
      rings.slice(0, 4).forEach(function (ring) {
        findHtml += '<div class="find-row">' +
          '<span class="' + seatColor(ring.a) + '">' +
          escapeHtml(clampName(nameOf(ring.a))) + "</span> &amp; " +
          '<span class="' + seatColor(ring.b) + '">' +
          escapeHtml(clampName(nameOf(ring.b))) + "</span>" +
          '<span class="find-delta">+' +
          Number(ring.delta || 0).toFixed(1) + "</span></div>";
      });
      var groups = ringGroups(rings);
      groups.forEach(function (group) {
        findHtml += '<div class="find-ring">RING &middot; ' +
          group.map(function (seat) {
            return escapeHtml(clampName(nameOf(seat)));
          }).join(" &middot; ") + "</div>";
      });
      findHtml += '<div class="find-note">Reported, never scored.' +
        (groups.length ? "" : " One thread is not a cartel.") + "</div>";
    }
    if (ringnote.dataset.html !== findHtml) {
      ringnote.dataset.html = findHtml;
      ringnote.innerHTML = findHtml;
    }
    ringnote.classList.add("show");
  }

  // A small paper tag in an accent colour, used for the FLAGGED caption on a
  // red thread.
  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = text.toUpperCase();
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  // The map also carries the canonical alphabet so feed lines can spell
  // messages the way the stage does.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames, glyphs) {
    var table = tableNames || [];
    var alphabet = glyphs || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      },
      glyph: function (t) {
        return alphabet[t] !== undefined ? alphabet[t] : "?";
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  // Round numbers in events are 0-based per the sim; a payload that counts
  // from 1 is tolerated by reading the first round event.
  function roundBase(events) {
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind === "round") return events[i].round === 1 ? 1 : 0;
    }
    return 0;
  }

  function meetingText(event, name) {
    var arrow = event.game === "pd" ? " ⇄ " : " → ";
    var head = name(event.seat) + arrow + name(event.other) + " — " +
      gameName(event.game) + ": ";
    var body;
    if (event.game === "pd") {
      if (event.moveA === event.moveB) {
        body = event.moveA === 0 ? "both cooperate" : "both defect";
      } else if (event.moveA === 0) {
        body = name(event.seat) + " cooperates, " + name(event.other) +
          " defects";
      } else {
        body = name(event.seat) + " defects, " + name(event.other) +
          " cooperates";
      }
    } else {
      body = moveText(event.game, true, event.moveA) + ", " +
        moveText(event.game, false, event.moveB);
    }
    var broken = event.game === "ultimatum" && event.payA === 0 &&
      event.payB === 0;
    if (broken) return head + body + " — BROKEN (0 / 0)";
    return head + body + " (+" + event.payA + " / +" + event.payB + ")";
  }

  // `ctx` carries what a line needs from earlier events: the round's pairs,
  // every seat's payoff list (the score is a MEDIAN, so the whole list is the
  // running tally) and the round count.
  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "Eight aliases, one public record, nothing forgotten.";
      case "round":
        return "Tables: " + (event.pairs || []).map(function (p) {
          return name(p.a) + " & " + name(p.b) + " — " + gameName(p.game);
        }).join(" · ");
      case "meeting":
        return meetingText(event, name);
      case "gossip":
        return name(event.seat) + " on " + name(event.other) + ": \"" +
          (event.text || "") + "\"";
      case "end":
        return endText(event, ctx, nameMap);
      default: return JSON.stringify(event);
    }
  }

  function medianOf(values) {
    if (!values || !values.length) return 0;
    var sorted = values.slice().sort(function (a, b) { return a - b; });
    var n = sorted.length;
    return n % 2 ? sorted[(n - 1) / 2] :
      (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
  }

  function endText(event, ctx, nameMap) {
    var best = -1;
    var bestScore = -1;
    for (var seat = 0; seat < 8; seat++) {
      var score = medianOf(ctx.pay[seat]);
      if (score > bestScore) { bestScore = score; best = seat; }
    }
    if (best < 0) return "Final.";
    return "Final — " + clampName(nameMap.seat(best)) + ", median " +
      bestScore.toFixed(1) + " coins" +
      (event.text === "deadline" ? " — episode deadline." : ".");
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "ROUND " + (block + 1);
  }

  // Renders the full transcript grouped into one section per round.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views. `rings` is the flagged-pair list of the frame being shown —
  // it is passed in rather than read from the last drawn frame, because a
  // scrub can move the feed and the canvas to different ticks. `results`
  // carries only the COUNT of flagged pairs, so the pairs have to come from
  // the table state.
  function renderFeed(element, events, nameMap, currentIndex, rings) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var ringList = rings || [];
    var base = roundBase(events);
    var html = "";
    var lastBlock = null;
    var ctx = { pairs: null, pay: [[], [], [], [], [], [], [], []] };
    var lastMemo = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) +
          "</div>";
        lastBlock = block;
      }
      if (event.kind === "round") ctx.pairs = event.pairs || [];
      if (event.kind === "meeting") {
        ctx.pay[event.seat].push(event.payA);
        ctx.pay[event.other].push(event.payB);
      }
      // A meeting both sides played kindly is the thing the game rewards, so
      // it carries the scoring colour.
      var scored = event.kind === "meeting" &&
        isKind(event.game, true, event.moveA) &&
        isKind(event.game, false, event.moveB);
      // The ring findings land just before the final line: they are an
      // observation about the episode, never a rescoring of it.
      if (event.kind === "end") {
        ringList.forEach(function (ring) {
          html += '<div class="feed-line feed-ring' +
            (i >= limit ? " feed-future" : "") + '">' +
            escapeHtml("RING: " + clampName(nameMap.seat(ring.a)) + " · " +
              clampName(nameMap.seat(ring.b)) + " (+" +
              Number(ring.delta || 0).toFixed(1) + " coins between them)") +
            "</div>";
        });
      }
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "meeting" ? " seat" + (event.seat % COLORS.length) :
          "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (scored ? " feed-score seat" + (event.seat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap, ctx)) + "</div>";
      // Memos: say-styled, only when the seat's memo changed.
      if (event.kind === "meeting") {
        [[event.seat, event.memoA], [event.other, event.memoB]]
          .forEach(function (entry) {
            if (!entry[1] || entry[1] === lastMemo[entry[0]]) return;
            lastMemo[entry[0]] = entry[1];
            html += '<div class="feed-line feed-say' +
              (i >= limit ? " feed-future" : "") + '">' +
              escapeHtml(clampName(nameMap.seat(entry[0])) + " memo: " +
                nameMap.text(entry[1])) + "</div>";
          });
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when the round opened (the paired avatars slide in from it), when each
  // pair's meeting landed (the verdict icon and the flying coins fade from
  // it), and when the last note fluttered onto the board.
  function makeEffects() {
    var seen = 0;
    var roundAt = null;
    var meetAt = [null, null, null, null];
    var gossipAt = null;
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest events get to animate — replaying every historical verdict as
      // a fresh flash would strobe the plaza.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "round") {
            roundAt = animate ? now : null;
            meetAt = [null, null, null, null];
          } else if (event.kind === "meeting") {
            meetAt[event.pair] = animate ? now : null;
          } else if (event.kind === "gossip") {
            gossipAt = animate ? now : null;
          }
        }
      },
      reset: function () {
        seen = 0;
        roundAt = null;
        meetAt = [null, null, null, null];
        gossipAt = null;
      },
      view: function () {
        return {
          effects: {
            roundAt: roundAt,
            meetAt: meetAt.slice(),
            gossipAt: gossipAt
          }
        };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  // Transport geometry lives on :root so the CSS can use it: --band is the
  // transport bar's height (the endcard stops there, and no overlay is ever
  // placed inside the band) and --hudscale scales HUD sizes with the frame,
  // which is what keeps the scorebug legible in a 360 px featured-match
  // iframe.
  function relayout() {
    var root = document.documentElement;
    var transport = document.getElementById("transport");
    var band = transport ?
      Math.round(transport.getBoundingClientRect().height) : 0;
    root.style.setProperty("--band", band + "px");
    var scale = Math.max(0.75, Math.min(1.25, window.innerWidth / 960));
    root.style.setProperty("--hudscale",
      String(Math.round(scale * 1000) / 1000));
  }
  window.addEventListener("load", relayout);
  window.addEventListener("resize", relayout);

  function phaseText(state, nameMap) {
    switch (state.phase) {
      case "deal": return "TABLES MEET";
      case "resolve": return "SETTLING";
      default: return "";
    }
  }

  function matchHeader(state, config, nameMap) {
    var parts = [];
    if (state) {
      var played = state.roundsPlayed || 0;
      var inRound = state.phase === "deal" || state.phase === "resolve";
      var total = state.rounds || (config && config.rounds) || 0;
      if (state.gameDone || state.done) {
        return "FINAL — " + played + " ROUND" + (played === 1 ? "" : "S");
      }
      parts.push("ROUND " + (played + (inRound ? 1 : 0)) +
        (total ? " / " + total : ""));
      var phase = phaseText(state, nameMap);
      if (phase) parts.push(phase);
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    // RANKED, because the one statistic Ledger scores is the median and a
    // leaderboard in seat order is not a leaderboard. Each plate carries the
    // rank, the alias, the median and a conduct bar -- the same value the
    // gauge on the board draws, so the two never disagree. The pip strip and
    // the repeated "median" label are gone: at 1280px they needed about
    // 217px of a 149px plate and were silently clipped.
    // Ties break on the mean, the same way updateEndscreen breaks them, so
    // the plate row and the final standings never disagree about who is
    // first. Six seats on 6.0 is an ordinary Ledger result.
    var order = state.seats.map(function (_, index) { return index; });
    order.sort(function (l, r) {
      var byScore = Number(state.seats[r].score || 0) -
        Number(state.seats[l].score || 0);
      if (byScore) return byScore;
      var byMean = Number(state.seats[r].mean || 0) -
        Number(state.seats[l].mean || 0);
      if (byMean) return byMean;
      return l - r;
    });
    var html = "";
    order.forEach(function (index, rank) {
      var seat = state.seats[index];
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      var kind = seat.kind || 0;
      var harsh = seat.harsh || 0;
      var played = kind + harsh;
      var share = played ? kind / played : 0;
      var band = share > 0.7 ? "good" : share > 0.4 ? "fair" : "poor";
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<div class="plate-row">' +
        '<span class="plate-rank">' + (rank + 1) + "</span>" +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        '<span class="plate-score">' +
        Number(seat.score || 0).toFixed(1) + "</span>" +
        "</div>" +
        '<div class="plate-bar"><i class="' + band + '" style="width:' +
        Math.round(share * 100) + '%"></i></div>' +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.rounds || 0) +
          " of " + (results.maxRounds || results.rounds || 0) + " rounds";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below, and the ring
  // findings under them — published, never scored. `rings` is the flagged-pair
  // list of the frame the endcard is being built over; `results` carries only
  // their count.
  function updateEndscreen(container, results, show, nameMap, rings) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var ringList = rings || [];
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var mean = results.mean || [];
    var meetings = results.meetings || [];
    var kind = results.kind || [];
    var harsh = results.harsh || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byScore = (scores[b] || 0) - (scores[a] || 0);
      if (byScore) return byScore;
      return (mean[b] || 0) - (mean[a] || 0);
    });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      escapeHtml(names[topIndex]) + " TOPS THE LEDGER" : "ALL LEVEL";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.rounds || 0) + " ROUND" +
      ((results.rounds || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">median</span>' +
      '<span class="end-head">mean</span>' +
      '<span class="end-head">meetings</span>' +
      '<span class="end-head">kind</span>' +
      '<span class="end-head">harsh</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell((scores[i] || 0).toFixed(1)) +
        cell((mean[i] || 0).toFixed(1)) +
        cell(meetings[i] || 0) +
        cell(kind[i] || 0) +
        cell(harsh[i] || 0);
    });
    html += "</div>";
    if (ringList.length) {
      html += '<div class="end-rings">';
      ringList.forEach(function (ring) {
        html += "<div>" + escapeHtml("RING: " +
          clampName(nameMap ? nameMap.seat(ring.a) : "Seat " + ring.a) +
          " · " +
          clampName(nameMap ? nameMap.seat(ring.b) : "Seat " + ring.b) +
          " — they paid each other " + Number(ring.delta || 0).toFixed(1) +
          " coins more than they earned elsewhere (reported, never scored)") +
          "</div>";
      });
      html += "</div>";
    }
    html += "</div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
      relayout();
    };
    refresh();
    relayout();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.pairs = state.pairs || [];
    view.gossip = state.gossip || [];
    view.rings = state.rings || [];
    view.phase = state.phase || "";
    view.round = typeof state.round === "number" ? state.round : -1;
    view.roundsPlayed = state.roundsPlayed || 0;
    view.rounds = state.rounds || 0;
    view.nameOf = function (i) { return nameMap.seat(i); };
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var slot = -1;
      // Player pages get no policyNames (they must not learn who is
      // behind a seat) and a redacted state (no pairs, no glyphs), so
      // their map degrades to the table aliases and empty booths.
      var nameMap = makeNameMap([], null, []);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              if (typeof latest.slot === "number") slot = latest.slot;
              nameMap = makeNameMap(seatNames(latest), latest.policyNames,
                latest.glyphs);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined, latest.rings || []);
              }
              if (options.clock) {
                options.clock.textContent =
                  matchHeader(latest, latest, nameMap);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap,
                latest ? latest.rings || [] : []);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          if (slot >= 0 && view.seats[slot]) view.seats[slot].own = true;
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per round, plus a
  // LABELLED, CLICKABLE button per beat — every meeting, every note, and the
  // end. The buttons sit on top of the track, so babel's drag-to-seek still
  // works everywhere else on it.
  function buildScrub(container, events, onSeek, nameMap) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var base = roundBase(events);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round - base;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });

    // One beat marker. `kind` is the CSS class set, `team` the seat colour
    // (-1 for none) and `label` the accessible name a spectator reads.
    function markBeat(tick, kind, team, label) {
      var button = document.createElement("button");
      button.type = "button";
      button.className = "beat-marker " + kind +
        (team >= 0 ? " seat" + (team % COLORS.length) : "");
      button.setAttribute("aria-label", label);
      button.title = label;
      button.style.left = tick + "%";
      button.addEventListener("pointerdown", function (evt) {
        evt.stopPropagation();
      });
      button.addEventListener("click", function (evt) {
        evt.stopPropagation();
        onSeek(button.dataset.index ? Number(button.dataset.index) : 0);
      });
      container.appendChild(button);
      return button;
    }

    function who(seat) {
      return nameMap ? clampName(nameMap.seat(seat)) : "Seat " + seat;
    }

    events.forEach(function (event, i) {
      var tick = (i + 1) / events.length * 100;
      var round = "Round " + (event.round - base + 1);
      var button = null;
      if (event.kind === "meeting") {
        var kindA = isKind(event.game, true, event.moveA);
        var kindB = isKind(event.game, false, event.moveB);
        var broken = event.game === "ultimatum" && event.payA === 0 &&
          event.payB === 0;
        if (broken) {
          button = markBeat(tick, "beat-meet broken", -1,
            round + " — deal broken");
        } else if (kindA && kindB) {
          button = markBeat(tick, "beat-meet kind", event.seat,
            round + " — " + who(event.seat) + " and " + who(event.other) +
            " settle kindly");
        } else if (!kindA && !kindB) {
          button = markBeat(tick, "beat-meet mutual", -1,
            round + " — " + who(event.seat) + " and " + who(event.other) +
            " both take");
        } else {
          var taker = kindA ? event.other : event.seat;
          var victim = kindA ? event.seat : event.other;
          button = markBeat(tick, "beat-meet harsh", taker,
            round + " — " + who(taker) + " takes from " + who(victim));
        }
      } else if (event.kind === "gossip") {
        button = markBeat(tick, "beat-gossip", event.seat,
          round + " — " + who(event.seat) + " reviews " + who(event.other));
      } else if (event.kind === "end") {
        button = markBeat(tick, "beat-end death", -1, "Final");
      }
      if (button) button.dataset.index = String(i + 1);
    });

    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames,
      config.glyphs);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        // Every seek dismisses the endcard: setIndex re-runs updateEndscreen
        // with show = (index >= events.length), which is false for any seek
        // that is not to the very end.
        setIndex(next, true);
      }, nameMap);
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        var state = states[Math.min(index, states.length - 1)] ||
          { seats: [], pairs: [], phase: "", roundsPlayed: 0 };
        // The alphabet is per episode; frames may omit it, the config
        // never does.
        if (!state.glyphs && config.glyphs) {
          state = Object.assign({}, state, { glyphs: config.glyphs });
        }
        return state;
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        // The flagged pairs of the frame this index re-derives to — the same
        // state the canvas is about to be drawn from — so the feed's and the
        // endcard's RING lines describe the tick the viewer is looking at,
        // including after a scrub back to an earlier tick.
        var rings = currentState().rings || [];
        if (options.feed) {
          renderFeed(options.feed, events, nameMap, index, rings);
        }
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent =
            matchHeader(currentState(), config, nameMap);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap, rings);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at — the event
        // just absorbed — so the meeting gets read and the verdict gets
        // seen before the next beat.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "meeting" ? 1400 :
          shown && shown.kind === "gossip" ? 900 :
          shown && shown.kind === "round" ? 700 :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.LedgerRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle,
    relayout: relayout
  };
})();
