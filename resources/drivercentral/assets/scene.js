// Draws a banner's art from its <svg class="scene"> data attributes, then shrinks the
// headline, chips and subtitle until they end clear of it. README.md lists the styles.
(() => {
  const ICONS = {
    bulb: '<path d="M-11 2 C-19 -5 -18 -22 0 -23 C18 -22 19 -5 11 2 L9 7 H-9 Z"/><path d="M-7 13 H7"/><path d="M-4 18 H4"/>',
    motion: '<circle r="5" fill="#fff" stroke="none"/><path d="M-12 -12 A17 17 0 0 0 -12 12"/><path d="M12 -12 A17 17 0 0 1 12 12"/><path d="M-19 -19 A27 27 0 0 0 -19 19"/><path d="M19 -19 A27 27 0 0 1 19 19"/>',
    thermo: '<path d="M-4 2 V-18 A4 4 0 0 1 4 -18 V2"/><circle cy="7" r="7"/>',
    plug: '<rect x="-13" y="-12" width="26" height="20" rx="5"/><path d="M-6 -12 V-21"/><path d="M6 -12 V-21"/><path d="M0 8 V16"/>',
    lock: '<rect x="-15" y="-9" width="30" height="24" rx="5"/><path d="M-9 -9 V-16 A9 9 0 0 1 9 -16 V-9"/><circle cy="3" r="2.6" fill="#fff" stroke="none"/>',
    remote: '<rect x="-13" y="-19" width="26" height="38" rx="7"/><circle cy="-9" r="3"/><circle cy="1" r="3"/><circle cy="11" r="3"/>',
    strip: '<rect x="-21" y="-9" width="42" height="18" rx="5"/><circle cx="-10" r="3"/><circle cx="0" r="3"/><circle cx="10" r="3"/><path d="M21 0 H26"/>',
    lightstrip: '<path d="M-22 -4 C-12 -14 -4 6 6 -4 S20 2 22 -6" stroke-width="7" stroke-opacity="0.35"/><path d="M-22 -4 C-12 -14 -4 6 6 -4 S20 2 22 -6"/><circle cx="-14" cy="-8" r="2.4" fill="#fff" stroke="none"/><circle cx="-1" cy="-2" r="2.4" fill="#fff" stroke="none"/><circle cx="13" cy="-3" r="2.4" fill="#fff" stroke="none"/><path d="M-22 -4 V12"/>',
    switch: '<rect x="-14" y="-19" width="28" height="38" rx="6"/><rect x="-7" y="-11" width="14" height="22" rx="3"/>',
    meter: '<path d="M-17 8 A18 18 0 0 1 17 8"/><path d="M0 8 L8 -6"/><circle cy="8" r="2.6" fill="#fff" stroke="none"/>',
    sound: '<path d="M-14 -6 H-7 L2 -14 V14 L-7 6 H-14 Z"/><path d="M8 -7 A10 10 0 0 1 8 7"/><path d="M13 -13 A18 18 0 0 1 13 13"/>',
    moon: '<path d="M7 -17 A17 17 0 1 0 15 9 A13 13 0 0 1 7 -17 Z"/>',
    sunrise: '<path d="M-20 10 H20"/><path d="M-12 10 A12 12 0 0 1 12 10"/><path d="M0 -15 V-9"/><path d="M-15 -6 L-11 -2"/><path d="M15 -6 L11 -2"/>',
    clock: '<circle r="17"/><path d="M0 -9 V0 L7 5"/>',
    note: '<path d="M-6 12 V-14 L12 -18 V8"/><circle cx="-11" cy="12" r="5"/><circle cx="7" cy="8" r="5"/>',
    glow: '<circle r="8"/><path d="M0 -20 V-15"/><path d="M0 15 V20"/><path d="M-20 0 H-15"/><path d="M15 0 H20"/><path d="M-14 -14 L-11 -11"/><path d="M11 11 L14 14"/><path d="M-14 14 L-11 11"/><path d="M11 -11 L14 -14"/>',
    door: '<rect x="-12" y="-19" width="24" height="38" rx="3"/><circle cx="6" cy="1" r="2.4" fill="#fff" stroke="none"/>',
    fan: '<circle r="4"/><path d="M0 -4 C-4 -16 8 -20 10 -10 C11 -5 5 -3 0 -4"/><path d="M3.5 2 C14 8 8 19 -1 16 C-6 14 -4 7 3.5 2"/><path d="M-3.5 2 C-14 -4 -16 8 -7 12 C-3 13 0 7 -3.5 2"/>',
    box: '<rect x="-20" y="-10" width="40" height="20" rx="4"/><circle cx="-11" r="2.2" fill="#fff" stroke="none"/><path d="M2 0 H13"/>',
    tv: '<rect x="-20" y="-14" width="40" height="26" rx="4"/><path d="M-8 18 H8"/>',
    globe: '<circle r="17"/><path d="M-17 0 H17"/><path d="M0 -17 C-9 -8 -9 8 0 17"/><path d="M0 -17 C9 -8 9 8 0 17"/>',
    vars: '<path d="M-12 -14 C-18 -8 -18 8 -12 14"/><path d="M12 -14 C18 -8 18 8 12 14"/><path d="M-6 -6 L6 6"/><path d="M6 -6 L-6 6"/>',
    sigma: '<path d="M12 -15 H-11 L3 0 L-11 15 H12"/>',
    branch: '<circle cx="-12" cy="0" r="4"/><circle cx="12" cy="-12" r="4"/><circle cx="12" cy="12" r="4"/><path d="M-8 0 H0 L8 -10"/><path d="M0 0 L8 10"/>',
    link: '<path d="M-3 7 L-8 12 A7 7 0 0 1 -18 2 L-12 -4 A7 7 0 0 1 -2 -4"/><path d="M3 -7 L8 -12 A7 7 0 0 1 18 -2 L12 4 A7 7 0 0 1 2 4"/><path d="M-6 6 L6 -6"/>',
    water: '<path d="M-20 -4 C-14 -10 -8 2 -2 -4 S10 2 16 -4"/><path d="M-20 8 C-14 2 -8 14 -2 8 S10 14 16 8"/>',
    flame: '<path d="M0 -18 C10 -8 13 0 10 8 A11 11 0 0 1 -10 8 C-12 0 -6 -4 -4 -10 C-2 -4 2 -2 3 -6 C4 -10 2 -14 0 -18 Z"/>',
    calendar: '<rect x="-16" y="-13" width="32" height="28" rx="4"/><path d="M-16 -4 H16"/><path d="M-8 -18 V-10"/><path d="M8 -18 V-10"/>',
    chip: '<rect x="-14" y="-14" width="28" height="28" rx="4"/><path d="M-6 -20 V-14 M0 -20 V-14 M6 -20 V-14 M-6 14 V20 M0 14 V20 M6 14 V20 M-20 -6 H-14 M-20 6 H-14 M14 -6 H20 M14 6 H20"/>',
  };
  const STAR = '<path d="M0 -9 L2.5 -2.5 L9 0 L2.5 2.5 L0 9 L-2.5 2.5 L-9 0 L-2.5 -2.5 Z" fill="#fff" stroke="none"/>';
  const STROKE = 'fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"';
  // Art is drawn in the spotlight's 2048x424 space, inside x 1400-2010, around the hub at (1700, 212).
  const HX = 1700, HY = 212;
  const r0 = (n) => Math.round(n);

  const defs = (t) => `<defs><radialGradient id="hubGlow"><stop offset="0" stop-color="${t}" stop-opacity="0.55"/><stop offset="1" stop-color="${t}" stop-opacity="0"/></radialGradient>`
    + `<linearGradient id="link" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="${t}" stop-opacity="0.9"/><stop offset="1" stop-color="#ffffff" stop-opacity="0.35"/></linearGradient></defs>`;

  // In a circle the logo's diagonal is 106 px, so any shape keeps about 21 px inside; a wordmark
  // sits in a pill. A "-light" hub is white, for a brand whose kit has no logo for dark backgrounds.
  function hub(c, x = HX, y = HY) {
    const g = `<circle cx="${x}" cy="${y}" r="130" fill="url(#hubGlow)"/>`;
    const [shape, tone] = c.hub.split("-");
    const fill = tone === "light" ? 'fill="#ffffff" stroke="rgba(255,255,255,0.85)"' : 'fill="#1b1d24" stroke="rgba(255,255,255,0.55)"';
    if (shape === "pill") {
      return g + `<rect x="${x - 140}" y="${y - 54}" width="280" height="108" rx="54" fill="none" stroke="${c.tint}" stroke-opacity="0.45" stroke-width="1.5"/>`
        + `<rect x="${x - 126}" y="${y - 40}" width="252" height="80" rx="40" ${fill} stroke-width="2.5"/>`
        + `<image href="${c.logo}" x="${x - 108}" y="${y - 27}" width="216" height="54" preserveAspectRatio="xMidYMid meet"/>`;
    }
    const lh = 106 / Math.sqrt(1 + c.aspect * c.aspect), lw = c.aspect * lh;
    return g + `<circle cx="${x}" cy="${y}" r="88" fill="none" stroke="${c.tint}" stroke-opacity="0.45" stroke-width="1.5"/>`
      + `<circle cx="${x}" cy="${y}" r="74" ${fill} stroke-width="2.5"/>`
      + `<image href="${c.logo}" x="${r0(x - lw / 2)}" y="${r0(y - lh / 2)}" width="${r0(lw)}" height="${r0(lh)}" preserveAspectRatio="xMidYMid meet"/>`;
  }

  function node(x, y, icon, r = 38, square = false) {
    const body = square ? `<rect x="${x - r}" y="${y - r}" width="${2 * r}" height="${2 * r}" rx="14"/>` : `<circle cx="${x}" cy="${y}" r="${r}"/>`;
    return `<g fill="#181a21" stroke="rgba(255,255,255,0.40)" stroke-width="2">${body}</g><g ${STROKE} transform="translate(${x} ${y})">${ICONS[icon] || ""}</g>`;
  }

  const pill = (x, y, w, h, label, mono) => `<rect x="${r0(x - w / 2)}" y="${y - h / 2}" width="${r0(w)}" height="${h}" rx="${h / 2}" fill="#181a21" stroke="rgba(255,255,255,0.40)" stroke-width="2"/>`
    + `<text x="${x}" y="${y + 6}" text-anchor="middle" fill="#fff" font-family="${mono ? "ui-monospace, Menlo, monospace" : "Inter, sans-serif"}" font-size="17">${label}</text>`;

  const STYLES = {
    // Six devices linked to the hub: a network of things the driver controls.
    mesh(c) {
      const p = [[1498, 112], [1462, 296], [1616, 368], [1848, 74], [1962, 192], [1872, 352]];
      const ring = [[0, 1], [1, 2], [2, 5], [5, 4], [4, 3], [3, 0]];
      let s = '<g stroke="url(#link)" stroke-width="2.4" stroke-linecap="round">' + p.map(([x, y]) => `<path d="M${HX} ${HY} L${x} ${y}"/>`).join("") + "</g>";
      s += '<g stroke="rgba(255,255,255,0.22)" stroke-width="1.8" stroke-dasharray="4 9" stroke-linecap="round">' + ring.map(([a, b]) => `<path d="M${p[a][0]} ${p[a][1]} L${p[b][0]} ${p[b][1]}"/>`).join("") + "</g>";
      s += `<g fill="${c.tint}">` + p.map(([x, y]) => `<circle cx="${(HX + x) >> 1}" cy="${(HY + y) >> 1}" r="4"/>`).join("") + "</g>";
      return s + hub(c) + p.map(([x, y], i) => node(x, y, c.icons[i], [40, 40, 34, 38, 40, 38][i])).join("");
    },
    // Pulses from the hub under a night sky: sound, light, sleep.
    rings(c) {
      let s = [116, 156, 198, 242, 288].map((r, k) => `<circle cx="${HX}" cy="${HY}" r="${r}" fill="none" stroke="${c.tint}" stroke-opacity="${(0.55 - k * 0.09).toFixed(2)}" stroke-width="${(2.2 - k * 0.25).toFixed(2)}"/>`).join("");
      s += [[1470, 70, 0.9], [1560, 40, 0.6], [1930, 60, 1], [1990, 150, 0.7], [1450, 360, 0.6], [1985, 330, 0.8], [1790, 30, 0.5]].map(([x, y, k]) => `<g transform="translate(${x} ${y}) scale(${k})" opacity="0.8">${STAR}</g>`).join("");
      return s + hub(c) + [[1478, 150], [1922, 150], [1500, 320], [1900, 320]].map(([x, y], i) => node(x, y, c.icons[i], 32)).join("");
    },
    // Ripples spreading under the hub, with rising bubbles: water.
    ripples(c) {
      let s = [116, 156, 198, 242, 288].map((r, k) => `<ellipse cx="${HX}" cy="${HY + 70}" rx="${r}" ry="${r0(r * 0.3)}" fill="none" stroke="${c.tint}" stroke-opacity="${(0.55 - k * 0.09).toFixed(2)}" stroke-width="${(2.2 - k * 0.25).toFixed(2)}"/>`).join("");
      s += [[1560, 150, 6], [1590, 96, 4], [1842, 128, 5], [1874, 70, 3.5], [1508, 210, 3], [1910, 196, 4]].map(([x, y, r]) => `<circle cx="${x}" cy="${y}" r="${r}" fill="none" stroke="rgba(255,255,255,0.55)" stroke-width="1.8"/>`).join("");
      return s + hub(c, HX, HY - 20) + [[1476, 290], [1924, 290], [1540, 368], [1860, 368]].map(([x, y], i) => node(x, y, c.icons[i], 32)).join("");
    },
    // A live line chart behind the hub, with labeled series: data over time.
    chart(c) {
      let s = '<g stroke="rgba(255,255,255,0.14)" stroke-width="1.5" stroke-dasharray="3 8">' + [90, 170, 250, 330].map((y) => `<path d="M1420 ${y} H2000"/>`).join("") + "</g>";
      const pts = [];
      for (let i = 0, x = 1420; x <= 2000; i++, x += 36) pts.push([x, r0(300 - 70 * Math.sin(i / 2.2) - 30 * Math.sin(i / 0.9) - i * 6)]);
      const line = pts.map((p) => p.join(",")).join(" ");
      s += `<polyline points="${line}" fill="none" stroke="${c.tint}" stroke-width="7" stroke-opacity="0.25" stroke-linejoin="round"/>`;
      s += `<polyline points="${line}" fill="none" stroke="${c.tint}" stroke-width="3" stroke-linejoin="round"/>`;
      s += `<polygon points="1420,380 ${line} 2000,380" fill="${c.tint}" fill-opacity="0.10"/>`;
      s += pts.filter((_, i) => i % 3 === 0).map(([x, y]) => `<circle cx="${x}" cy="${y}" r="4.5" fill="#fff"/>`).join("");
      s += hub(c, HX, 196);
      return s + [[1500, 70], [1890, 96], [1910, 330]].map(([x, y], i) => (c.items[i] ? pill(x, y, 24 + 10.4 * c.items[i][1].length, 34, c.items[i][1], true) : "")).join("");
    },
    // A thermostat dial around the hub, with heat rising from the floor.
    dial(c) {
      const rx = 205, ry = 150, a0 = 140, a1 = 400, set = 330;
      const pt = (a, k = 1) => [HX + rx * k * Math.cos(a * Math.PI / 180), HY + ry * k * Math.sin(a * Math.PI / 180)];
      const [x0, y0] = pt(a0), [x1, y1] = pt(a1), [xs, ys] = pt(set);
      let s = `<path d="M${r0(x0)} ${r0(y0)} A${rx} ${ry} 0 1 1 ${r0(x1)} ${r0(y1)}" fill="none" stroke="rgba(255,255,255,0.18)" stroke-width="10" stroke-linecap="round"/>`;
      s += `<path d="M${r0(x0)} ${r0(y0)} A${rx} ${ry} 0 1 1 ${r0(xs)} ${r0(ys)}" fill="none" stroke="${c.tint}" stroke-width="10" stroke-linecap="round"/>`;
      for (let a = a0; a <= a1; a += 13) {
        const [p, q] = pt(a, 1.13), [u, v] = pt(a, 1.2);
        s += `<path d="M${r0(p)} ${r0(q)} L${r0(u)} ${r0(v)}" stroke="rgba(255,255,255,0.35)" stroke-width="2" stroke-linecap="round"/>`;
      }
      s += `<circle cx="${r0(xs)}" cy="${r0(ys)}" r="13" fill="#fff" stroke="${c.tint}" stroke-width="5"/>`;
      for (let k = 0; k < 3; k++) {
        const x = HX - 40 + k * 40;
        s += `<path d="M${x} 404 C${x - 12} 388 ${x + 12} 376 ${x} 360 S${x - 12} 332 ${x} 318" fill="none" stroke="${c.tint}" stroke-opacity="0.75" stroke-width="3" stroke-linecap="round"/>`;
      }
      return s + hub(c) + node(1452, 330, c.icons[0], 32) + node(1948, 330, c.icons[1], 32);
    },
    // Messages fanning out from the hub to labeled topics.
    topics(c) {
      const hx = 1560, ys = [64, 138, 212, 286, 360];
      let s = ys.map((y) => `<path d="M${hx} ${HY} C${hx + 110} ${HY} 1690 ${y} 1770 ${y}" fill="none" stroke="url(#link)" stroke-width="2.4"/><circle cx="${r0((hx + 1770) / 2 + 10)}" cy="${r0((HY + y) / 2)}" r="4" fill="${c.tint}"/>`).join("");
      s += hub(c, hx, HY);
      return s + ys.map((y, i) => (c.items[i] ? `<rect x="1770" y="${y - 26}" width="236" height="52" rx="14" fill="#181a21" stroke="rgba(255,255,255,0.40)" stroke-width="2"/>`
        + `<g ${STROKE} transform="translate(1798 ${y}) scale(0.62)">${ICONS[c.items[i][0]] || ""}</g>`
        + `<text x="1822" y="${y + 6}" fill="#fff" font-family="ui-monospace, Menlo, monospace" font-size="17">${c.items[i][1]}</text>` : "")).join("");
    },
    // Circuit traces from the hub to six pads: a board and what it runs.
    circuit(c) {
      const pads = [[1478, 92], [1458, 212], [1478, 332], [1922, 92], [1942, 212], [1922, 332]];
      let s = pads.map(([x, y]) => {
        const sx = x < HX ? HX - 60 : HX + 60, mx = (sx + x) >> 1;
        return `<path d="M${sx} ${HY + r0((y - HY) / 4)} H${mx} V${y} H${x}" fill="none" stroke="${c.tint}" stroke-opacity="0.85" stroke-width="3" stroke-linejoin="round"/><circle cx="${mx}" cy="${y}" r="5" fill="#181a21" stroke="${c.tint}" stroke-width="2.5"/>`;
      }).join("");
      s += [60, 364].map((y) => `<path d="M1560 ${y} H1840" stroke="rgba(255,255,255,0.16)" stroke-width="2" stroke-dasharray="2 10" stroke-linecap="round"/>`).join("");
      return s + hub(c) + pads.map(([x, y], i) => node(x, y, c.icons[i], 32, true)).join("");
    },
    // A grid of labeled tiles beside the hub: a set of tools.
    tiles(c) {
      const hx = 1540, cells = [[1730, 132], [1846, 132], [1962, 132], [1730, 292], [1846, 292], [1962, 292]];
      let s = cells.map(([x, y]) => `<path d="M${hx + 74} ${HY} C${hx + 120} ${HY} ${x - 90} ${y} ${x - 46} ${y}" fill="none" stroke="url(#link)" stroke-width="2" stroke-opacity="0.7"/>`).join("");
      s += hub(c, hx, HY);
      return s + cells.map(([x, y], i) => (c.items[i] ? `<rect x="${x - 46}" y="${y - 58}" width="92" height="92" rx="18" fill="#181a21" stroke="rgba(255,255,255,0.40)" stroke-width="2"/>`
        + `<g ${STROKE} transform="translate(${x} ${y - 12})">${ICONS[c.items[i][0]] || ""}</g>`
        + `<text x="${x}" y="${y + 56}" text-anchor="middle" fill="#c3c8d2" font-family="Inter, sans-serif" font-size="15" font-weight="500">${c.items[i][1]}</text>` : "")).join("");
    },
    // Sources on the left routed through the hub to screens on the right.
    matrix(c) {
      const ins = [70, 166, 262, 358].map((y) => [1460, y]), outs = [70, 166, 262, 358].map((y) => [1942, y]);
      const on = new Set(["0-1", "1-3", "2-0", "3-2"]);
      let s = "";
      for (let a = 0; a < 4; a++) for (let b = 0; b < 4; b++) {
        const [x0, y0] = ins[a], [x1, y1] = outs[b], lit = on.has(`${a}-${b}`);
        s += `<path d="M${x0 + 36} ${y0} C${HX - 60} ${y0} ${HX + 60} ${y1} ${x1 - 36} ${y1}" fill="none" ${lit ? `stroke="${c.tint}" stroke-width="3"` : 'stroke="rgba(255,255,255,0.12)" stroke-width="1.5"'}/>`;
      }
      return s + hub(c) + ins.map(([x, y]) => node(x, y, c.icons[0] || "box", 34)).join("") + outs.map(([x, y]) => node(x, y, c.icons[1] || "tv", 34)).join("");
    },
    // A glowing addressable LED strip curving behind the hub.
    strip(c) {
      const p = Array.from({ length: 42 }, (_, i) => [1418 + i * 14, HY + 120 * Math.sin(i / 6.5) - 10]);
      let s = `<path d="M${p.map(([x, y]) => `${r0(x)} ${r0(y)}`).join(" L")}" fill="none" stroke="rgba(255,255,255,0.18)" stroke-width="22" stroke-linecap="round" stroke-linejoin="round"/>`;
      s += p.map(([x, y], i) => { const col = `hsl(${(i * 9) % 360}, 95%, 62%)`; return `<circle cx="${r0(x)}" cy="${r0(y)}" r="12" fill="${col}" opacity="0.25"/><circle cx="${r0(x)}" cy="${r0(y)}" r="5" fill="${col}"/>`; }).join("");
      s += hub(c);
      return s + [[1500, 60, 0.8], [1930, 80, 1], [1960, 350, 0.7], [1470, 360, 0.6]].map(([x, y, k]) => `<g transform="translate(${x} ${y}) scale(${k})" opacity="0.8">${STAR}</g>`).join("");
    },
  };

  const items = (v) => (v || "").split("|").filter(Boolean).map((p) => (p.includes(":") ? p.split(":") : ["", p]));

  function draw(el, launch, aspect) {
    const d = el.dataset;
    const c = { logo: d.logo, aspect, hub: d.hub || "circle", tint: d.tint || getComputedStyle(document.documentElement).getPropertyValue("--glow").trim(), icons: (d.icons || "").split(",").map((s) => s.trim()), items: items(d.items) };
    const [w, h] = launch ? [1200, 600] : [2048, 424];
    el.setAttribute("viewBox", `0 0 ${w} ${h}`);
    el.setAttribute("style", `position:absolute;left:0;top:0;width:${w}px;height:${h}px`);
    if (d.style === "hero") {
      const [cx, cy, bw] = launch ? [926, 300, 400] : [1710, 212, 440];
      el.innerHTML = `<image href="${d.img}" x="${cx - bw / 2}" y="${cy - bw / 2}" width="${bw}" height="${bw}" preserveAspectRatio="xMidYMid meet" style="filter: drop-shadow(0 18px 40px rgba(0,0,0,0.5))"/>`;
      return launch ? 680 : 1360;
    }
    const body = defs(c.tint) + (STYLES[d.style] || STYLES.mesh)(c);
    el.innerHTML = launch ? `<g transform="translate(960 300) scale(0.68) translate(-1700 -212)">${body}</g>` : body;
    return launch ? 720 : 1360;
  }

  // Measures the text and chips themselves: a block's own box spans its column.
  function textRight(el) {
    const range = document.createRange();
    range.selectNodeContents(el);
    return Math.max(0, ...Array.from(range.getClientRects(), (b) => b.right));
  }

  function guard(max) {
    for (const el of document.querySelectorAll("h1, .sub")) {
      for (let size = parseFloat(getComputedStyle(el).fontSize); textRight(el) > max && size > 12; size -= 0.5) el.style.fontSize = size + "px";
    }
    const row = document.querySelector(".row");
    if (!row || !row.children.length) return;
    const boxes = Array.from(row.children, (c) => c.getBoundingClientRect());
    const left = Math.min(...boxes.map((b) => b.left)), right = Math.max(...boxes.map((b) => b.right));
    if (right > max) { row.style.transformOrigin = "left center"; row.style.transform = `scale(${(max - left) / (right - left)})`; }
  }

  const el = document.querySelector("svg.scene");
  if (!el) return;
  // The logo's shape sizes it in a circle hub, so it loads before the art is drawn.
  const logo = new Image();
  const go = () => {
    const max = draw(el, document.body.clientWidth < 1600, logo.naturalWidth && logo.naturalHeight ? logo.naturalWidth / logo.naturalHeight : 1);
    document.fonts.ready.then(() => guard(max));
  };
  if (el.dataset.logo) { logo.onload = go; logo.onerror = go; logo.src = el.dataset.logo; } else go();
})();
