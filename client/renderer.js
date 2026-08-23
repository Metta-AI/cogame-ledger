// Ledger shared renderer + drivers.
//
// This file is cogame-babel's client/renderer.js. Two things are Ledger's:
// the SCENE (computeLayout through drawTag) is the plaza instead of babel's
// two speaker/listener booths, and the EVENT-VOCABULARY helpers (describeEvent,
// phaseText, matchHeader, updateScorebug, updateEndscreen, buildScrub markers,
// makeEffects) know Ledger's five event kinds. Everything else — makeRenderer,
// loadImages, ellipsize, hexToRgb/shade/rgba, roundRect, wrapLines,
// drawParchment, makeNameMap, applyNames, clampName, isBaselineFiller,
// renderFeed's structure, escapeHtml, bindFeedToggle, stateToView, attachLive,
// attachReplay — is babel's chrome, carried across.
//
// One canvas scene (an octagonal plaza: eight avatar posts on the outer ring
// with a reputation halo and a memo parchment each, four tables in the inner
// ring where this round's pairs meet, resolution icons, flying coins, and red
// threads between flagged pairs) fed by three drivers: live /global websocket,
// live /player websocket, and replay (from the game's /replay websocket or the
// static wasm bundle). All state derivation happens server-side / wasm-side;
// this file only draws state objects:
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

  // The rings the last drawn frame carried. The endscreen is built once, at
  // the very end of playback, and its `results` object carries only the COUNT
  // of flagged pairs — the pairs themselves live in the table state, so the
  // scene parks them here for the endcard to name.
  var latestRings = [];

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
  // it so the whole seat block scales as one unit.
  var SEAT_BASE = 84;
  var NOTE_LINES = 3, NOTE_LINE_H = 12, NOTE_PAD = 6;
  var LABEL_GUTTER = 16;

  function noteHeight(scale) {
    return (NOTE_LINES * NOTE_LINE_H + NOTE_PAD * 2 - 2) * scale;
  }

  function seatBlock(size) {
    // The seat block: role tag headroom above the cog, the cog, then name,
    // score and the notes parchment below it. Parchment room is reserved
    // even while a seat has no notes: notes arrive without warning.
    var scale = size / SEAT_BASE;
    return {
      w: size * 1.9,
      above: size * 0.18,
      cogHalf: size / 2,
      below: size * 0.62 + 34 * scale + noteHeight(scale)
    };
  }

  // ---- The plaza -----------------------------------------------------------

  // A seat is not just its sprite: a role tag sits above it and the alias,
  // the median and the memo parchment sit below. The ring has to be solved
  // against the whole BLOCK or the bottom two avatars lose their parchments
  // off the edge of the canvas.
  function seatBlockAbove(size) {
    return size * 0.62;
  }

  function seatBlockBelow(size) {
    var scale = size / SEAT_BASE;
    return size * 0.72 + 30 * scale + noteHeight(scale);
  }

  function computeLayout(width, height) {
    // A fixed octagonal arena, solved per frame so it always fits: eight
    // avatar posts on the outer ring, four tables on the inner one. Callers
    // embed this viewer at wildly different sizes (the softmax.com featured
    // match is ~360 px wide), so the seat size shrinks until the ring, the
    // seat blocks and the margins all fit rather than being assumed to.
    var margin = Math.max(6, Math.min(width, height) * 0.025);
    var size = Math.min(SEAT_BASE, Math.min(width, height) * 0.15);
    var ring = 0;
    for (var attempt = 0; attempt < 40; attempt++) {
      var vertical = (height - 2 * margin - seatBlockAbove(size) - size -
        seatBlockBelow(size)) / 2;
      var horizontal = (width - 2 * margin - size * 1.95) / 2;
      ring = Math.min(vertical, horizontal);
      if (ring >= size * 1.05 || size <= 22) break;
      size *= 0.94;
    }
    size = Math.max(22, size);
    // Never let the ring collapse into the tables, even in a frame too short
    // to hold the whole block: a clipped parchment beats overlapping cogs.
    ring = Math.max(size * 0.95, ring);
    return {
      cx: width / 2,
      cy: margin + seatBlockAbove(size) + size / 2 + ring,
      span: Math.min(width, height),
      ring: ring,
      inner: Math.max(size * 0.9, ring * 0.44),
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
      x: layout.cx + Math.cos(a) * layout.ring,
      y: layout.cy + Math.sin(a) * layout.ring
    };
  }

  // Where a pair meets: the inner ring, on the bearing between its two posts.
  // Diametrically opposite posts cancel out, so fall back to one of them.
  function tableSpot(layout, a, b) {
    var aa = seatAngle(a);
    var ab = seatAngle(b);
    var x = (Math.cos(aa) + Math.cos(ab)) / 2;
    var y = (Math.sin(aa) + Math.sin(ab)) / 2;
    var len = Math.sqrt(x * x + y * y);
    if (len < 0.08) {
      x = Math.cos(aa + Math.PI / 8);
      y = Math.sin(aa + Math.PI / 8);
      len = 1;
    }
    return {
      x: layout.cx + x / len * layout.inner,
      y: layout.cy + y / len * layout.inner
    };
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
    latestRings = view.rings || [];

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

    // Where each seat stands this frame: home post, sliding in toward its
    // table for the length of the round.
    var slide = fx.roundAt === null || fx.roundAt === undefined ? 1 :
      eased((now - fx.roundAt) / SLIDE_MS);
    var spots = [];
    var seatPair = [];
    for (var s = 0; s < 8; s++) {
      spots.push(seatHome(layout, s));
      seatPair.push(-1);
    }
    pairs.forEach(function (pair, pi) {
      var table = tableSpot(layout, pair.a, pair.b);
      [pair.a, pair.b].forEach(function (seat) {
        if (typeof seat !== "number" || seat < 0 || seat > 7) return;
        seatPair[seat] = pi;
        if (!live) return;
        var home = seatHome(layout, seat);
        var pull = 0.42 * slide;
        spots[seat] = {
          x: home.x + (table.x - home.x) * pull,
          y: home.y + (table.y - home.y) * pull
        };
      });
    });

    // Red threads first, UNDER the avatars: the cartel is a picture.
    drawThreads(ctx, layout, view.rings || [], spots, scale);

    // Tables, resolution icons, flying coins.
    pairs.forEach(function (pair, pi) {
      var table = tableSpot(layout, pair.a, pair.b);
      var meetAt = fx.meetAt && fx.meetAt[pi];
      var age = typeof meetAt === "number" ? now - meetAt : null;
      drawTable(ctx, table, pair, view, size, scale, live);
      if (pair.resolved) {
        var alpha = age === null ? MEET_REST :
          age < MEET_HOLD_MS ? 1 :
          Math.max(MEET_REST, 1 - (age - MEET_HOLD_MS) / MEET_FADE_MS *
            (1 - MEET_REST));
        drawVerdict(ctx, table, pair, size, scale, alpha);
        drawCoins(ctx, table, pair, spots, scale, age);
      }
    });

    // Avatars: sprite, halo, alias plate, memo parchment.
    for (var i = 0; i < 8; i++) {
      drawAvatar(ctx, images, seats[i], i, spots[i], size, scale, {
        pair: seatPair[i],
        pairs: pairs,
        deciding: view.phase === "deal",
        done: !!view.done
      });
    }

    syncRail(view);
  }

  function drawPlaza(ctx, layout) {
    var r = layout.ring * 1.22;
    ctx.save();
    ctx.beginPath();
    for (var i = 0; i < 8; i++) {
      var a = -Math.PI / 2 + (i + 0.5) * Math.PI / 4;
      var x = layout.cx + Math.cos(a) * r;
      var y = layout.cy + Math.sin(a) * r;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.closePath();
    ctx.fillStyle = STRIP;
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.14)";
    ctx.lineWidth = 1.5;
    ctx.stroke();
    // The inner court the tables stand on.
    ctx.beginPath();
    ctx.arc(layout.cx, layout.cy, layout.inner * 1.9, 0, Math.PI * 2);
    ctx.strokeStyle = "rgba(242, 232, 216, 0.08)";
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.restore();
  }

  // A table in the inner ring: the subgame in WORDS plus a role tag per side.
  function drawTable(ctx, spot, pair, view, size, scale, live) {
    var w = size * 1.55;
    var h = size * 0.66;
    var lit = live && pair.game !== undefined && pair.game !== null;
    ctx.save();
    ctx.fillStyle = lit ? "rgba(36, 26, 18, 0.92)" : "rgba(18, 13, 9, 0.72)";
    ctx.strokeStyle = lit ? rgba(AMBER, 0.55) : "rgba(242, 232, 216, 0.14)";
    ctx.lineWidth = lit ? 2 : 1;
    roundRect(ctx, spot.x - w / 2, spot.y - h / 2, w, h, 5 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    if (lit) {
      ctx.font = "700 " + Math.max(9, Math.round(12 * scale)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = PAPER;
      ctx.fillText(ellipsize(ctx, gameName(pair.game), w - 8 * scale),
        spot.x, spot.y - h * 0.12);
      if (pair.game !== "pd") {
        ctx.font = "600 " + Math.max(7, Math.round(8.5 * scale)) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.fillStyle = GHOST;
        ctx.fillText(ellipsize(ctx, roleName(pair.game, true) + " · " +
          roleName(pair.game, false), w - 6 * scale), spot.x,
          spot.y + h * 0.28);
      }
    } else {
      ctx.font = "600 " + Math.max(7, Math.round(8.5 * scale)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = "rgba(242, 232, 216, 0.28)";
      ctx.fillText("EMPTY", spot.x, spot.y);
    }
    ctx.restore();
  }

  // Both kind: a handshake. One harsh: a knife pointing at the victim. Both
  // harsh: crossed knives. A rejected ultimatum: a snapped coin.
  function drawVerdict(ctx, spot, pair, size, scale, alpha) {
    var kindA = isKind(pair.game, true, pair.moveA);
    var kindB = isKind(pair.game, false, pair.moveB);
    var broken = pair.game === "ultimatum" && pair.payA === 0 &&
      pair.payB === 0;
    var r = size * 0.34;
    var y = spot.y - size * 0.62;
    ctx.save();
    ctx.globalAlpha = alpha;
    if (broken) {
      drawSnappedCoin(ctx, spot.x, y, r);
    } else if (kindA && kindB) {
      drawHandshake(ctx, spot.x, y, r);
    } else if (!kindA && !kindB) {
      drawKnife(ctx, spot.x - r * 0.45, y, r, -0.5);
      drawKnife(ctx, spot.x + r * 0.45, y, r, 0.5);
    } else {
      drawKnife(ctx, spot.x, y, r, kindB ? -0.35 : 0.35);
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
      drawTag(ctx, (from.x + to.x) / 2, (from.y + to.y) / 2, "RING",
        COLOR_HEX.red, scale);
    });
  }

  // Sprite, reputation halo, alias plate, and the memo parchment.
  function drawAvatar(ctx, images, seat, index, pos, size, scale, opts) {
    if (!seat || !pos) return;
    var color = seatColor(index);
    var sprite = images["soldier_" + SPRITE_KITS[index % SPRITE_KITS.length] +
      "_front.png"];

    // Halo FIRST, behind the cog: radius and alpha come from the seat's
    // kind/harsh record. This is the reputation, visible at a glance.
    drawHalo(ctx, pos, size, typeof seat.halo === "number" ? seat.halo : 0.5);

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

    // Everyone decides at the same time, so the "acting" ring is on all eight
    // seats while the round is open.
    if (opts.deciding && !opts.done) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 2;
      ctx.setLineDash([5, 5]);
      ctx.beginPath();
      ctx.arc(pos.x, pos.y, size * 0.66, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // Role tag over the cog while a round is on.
    var pair = opts.pair >= 0 ? opts.pairs[opts.pair] : null;
    if (pair && pair.game) {
      var tag = roleName(pair.game, pair.a === index);
      if (pair.game === "pd") tag = gameName(pair.game);
      drawTag(ctx, pos.x, pos.y - size * 0.58, tag, COLOR_HEX[color], scale);
    }

    // Alias plate. Never smaller than 11 px: the featured-match iframe is
    // about 360 px wide and an unreadable plate is an unreadable board.
    ctx.save();
    ctx.font = "600 " + Math.max(11, Math.round(13 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    ctx.fillStyle = PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    ctx.fillText(ellipsize(ctx, seat.name || "", size * 1.8), pos.x,
      pos.y + size * 0.66 + 12 * scale);

    // The score, in coins: the MEDIAN, which is the only ranked statistic.
    ctx.font = "700 " + Math.max(11, Math.round(13 * scale)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = AMBER;
    ctx.fillText(Number(seat.score || 0).toFixed(1) + " med", pos.x,
      pos.y + size * 0.66 + 27 * scale);
    ctx.restore();

    // Memo parchment: the reasoning in public.
    var bw = size * 1.9;
    drawParchment(ctx, pos.x - bw / 2, pos.y + size * 0.66 + 34 * scale, bw,
      seat.memo || "", scale);
  }

  // Gold above 0.7, pale above 0.4, cold grey below.
  function drawHalo(ctx, pos, size, halo) {
    var tint = halo > 0.7 ? AMBER : halo > 0.4 ? PAPER : GHOST;
    var radius = size * (0.52 + 0.28 * Math.max(0, Math.min(1, halo)));
    var alpha = 0.18 + 0.5 * Math.max(0, Math.min(1, halo));
    ctx.save();
    var glow = ctx.createRadialGradient(pos.x, pos.y, radius * 0.55,
      pos.x, pos.y, radius);
    glow.addColorStop(0, rgba(tint, 0));
    glow.addColorStop(1, rgba(tint, alpha * 0.5));
    ctx.fillStyle = glow;
    ctx.beginPath();
    ctx.arc(pos.x, pos.y, radius, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = rgba(tint, alpha);
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.arc(pos.x, pos.y, radius, 0, Math.PI * 2);
    ctx.stroke();
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
    }
    var ringnote = document.getElementById("ringnote");
    if (ringnote) {
      var groups = ringGroups(view.rings || []);
      var text = groups.map(function (group) {
        return "RING: " + group.map(function (seat) {
          return clampName(nameOf(seat));
        }).join(" · ");
      }).join("    ");
      if (ringnote.dataset.text !== text) {
        ringnote.dataset.text = text;
        ringnote.textContent = text;
        ringnote.classList.toggle("show", text.length > 0);
      }
    }
  }

  function drawParchment(ctx, x, y, w, text, scale) {
    var pad = NOTE_PAD * scale;
    var lineH = NOTE_LINE_H * scale;
    var h = noteHeight(scale);
    ctx.save();
    ctx.font = Math.round(10.5 * scale) + "px " + GLYPH_FONT;
    var lines = text ? wrapLines(ctx, text, w - pad * 2, NOTE_LINES) : [];
    ctx.fillStyle = text ? "rgba(242, 232, 216, 0.92)" :
      "rgba(242, 232, 216, 0.10)";
    ctx.strokeStyle = text ? CARD_EDGE : "rgba(242, 232, 216, 0.18)";
    ctx.lineWidth = 1;
    ctx.setLineDash(text ? [] : [3, 3]);
    roundRect(ctx, x, y, w, h, 3 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.setLineDash([]);
    // Folded corner.
    if (text) {
      ctx.beginPath();
      ctx.moveTo(x + w - 7 * scale, y);
      ctx.lineTo(x + w, y + 7 * scale);
      ctx.lineTo(x + w - 7 * scale, y + 7 * scale);
      ctx.closePath();
      ctx.fillStyle = "rgba(42, 31, 22, 0.25)";
      ctx.fill();
    }
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    if (text) {
      ctx.fillStyle = INK;
      lines.forEach(function (line, i) {
        ctx.fillText(line, x + pad, y + pad + i * lineH);
      });
    } else {
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(8 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillText("NO NOTES YET", x + pad, y + pad);
    }
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  // A small tag ("SPEAKS", "LEADS") in the seat's colour, pinned over the
  // cog.
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
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
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
        latestRings.forEach(function (ring) {
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
    // Every seat decides at the same time, so the "acting" marker is on all
    // eight while the round is open, not on one.
    var deciding = state.phase === "deal" && !state.gameDone;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var pips = "";
      for (var p = 0; p < Math.min(seat.kind || 0, 7); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      for (var q = 0; q < Math.min(seat.harsh || 0, 7); q++) {
        pips += '<span class="plate-pip hollow"></span>';
      }
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      var tag = seat.game ? gameName(seat.game) : "";
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (deciding ? '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' +
        Number(seat.score || 0).toFixed(1) + "</span>" +
        '<span class="plate-label">median</span>' +
        (tag ? '<span class="plate-tag">' + escapeHtml(tag) + "</span>" : "") +
        '<span class="plate-pips">' + pips + "</span>" +
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
  // findings under them — published, never scored.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
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
    if (latestRings.length) {
      html += '<div class="end-rings">';
      latestRings.forEach(function (ring) {
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
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent =
                  matchHeader(latest, latest, nameMap);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
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
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent =
            matchHeader(currentState(), config, nameMap);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
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
