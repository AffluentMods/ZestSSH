/// Inline SVG strings for OS brand logos.
///
/// Used by [OsCatalog] via `flutter_svg`'s `SvgPicture.string`. Keeping
/// the path data in code (rather than as bundled asset files) avoids
/// asset boilerplate and lets each entry stay close to its catalog
/// entry. The strings use a `currentColor` fill / stroke wherever the
/// brand allows a single accent - `flutter_svg` honours the `color`
/// argument we pass at render time, so the catalog's brand colour
/// drives the rendering.
///
/// Where a logo is multi-coloured (e.g. Ubuntu's Circle of Friends),
/// we keep the brand colour explicit in the SVG and the catalog
/// passes the same colour at render time as a no-op.
///
/// All viewBoxes are normalised to `0 0 24 24` so the catalog's `size`
/// argument scales them uniformly.
library;

class OsLogoSvgs {
  OsLogoSvgs._();

  // ── Ubuntu - Circle of Friends ─────────────────────────────────
  // Three filled circles equidistant around a centre on a thin orbit
  // ring. The classic Canonical mark. Circles are sized larger so
  // they read as the dominant element at small render sizes.
  static const String ubuntu = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="1.4"/>
  <circle cx="12" cy="3.5" r="3.0" fill="currentColor"/>
  <circle cx="4.6" cy="16.3" r="3.0" fill="currentColor"/>
  <circle cx="19.4" cy="16.3" r="3.0" fill="currentColor"/>
</svg>
''';

  // ── Debian - swirl ─────────────────────────────────────────────
  // Simplified Debian "open swirl" mark.
  static const String debian = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M16.2 14.6a5.4 5.4 0 1 1-3.2-9.5c.5 0 1 .05 1.5.18a4.4 4.4 0 0 0-1.1-.13 4.6 4.6 0 0 0-.3 9.2 4.5 4.5 0 0 0 3.1-1.1l.7.4-.7 1z"
        fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>
  <path d="M14.5 8.4l1.1-.5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/>
</svg>
''';

  // ── Apple / macOS ──────────────────────────────────────────────
  // Classic apple silhouette with bite + leaf. Path simplified from
  // the public domain mark. Uses currentColor so we can tint it.
  static const String apple = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M17.05 12.42c-.03-2.78 2.27-4.12 2.37-4.18-1.29-1.89-3.3-2.15-4.02-2.18-1.71-.17-3.34.99-4.21.99-.86 0-2.21-.97-3.63-.94-1.87.03-3.59 1.08-4.55 2.74-1.94 3.36-.5 8.34 1.39 11.07.93 1.34 2.04 2.85 3.49 2.79 1.4-.06 1.93-.91 3.62-.91 1.69 0 2.17.91 3.65.88 1.51-.03 2.46-1.36 3.39-2.71.99-1.43 1.4-2.82 1.42-2.89-.03-.01-2.72-1.05-2.75-4.16zM14.32 4.3c.77-.94 1.29-2.24 1.15-3.54-1.11.05-2.46.74-3.26 1.67-.71.83-1.34 2.16-1.18 3.43 1.24.1 2.51-.63 3.29-1.56z"
        fill="currentColor"/>
</svg>
''';

  // ── Windows - four tilted panes ────────────────────────────────
  // The Windows 10/11 mark: four equal squares with a small gap.
  static const String windows = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M3 5.5L11 4.4v7.1H3V5.5zM12 4.27L21 3v8.5h-9V4.27zM3 12.5h8v7.1L3 18.5v-6zM12 12.5h9V21l-9-1.27V12.5z"
        fill="currentColor"/>
</svg>
''';

  // ── Proxmox VE - typographic "PVE" wordmark on orange tile ─────
  // The official Proxmox mark we're approximating is a wordmark, not
  // a letter glyph - every previous "stylised P" attempt either
  // looked like a generic P or read as an unrelated symbol. This
  // version uses the brand's recognisable trio of capital letters
  // (P, V, E) on the orange-red tile, the same way Proxmox renders
  // it in their press kit and product chrome. Reads correctly at
  // 24px and stays legible at the 36px host-card size.
  static const String proxmox = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <rect x="2" y="2" width="20" height="20" rx="3.2" fill="#E56717"/>
  <text x="12" y="15.2" text-anchor="middle"
        font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif"
        font-size="8" font-weight="800"
        fill="#FFFFFF" letter-spacing="-0.2">PVE</text>
</svg>
''';

  // ── Raspberry Pi ───────────────────────────────────────────────
  // Berry cluster (4 berries around the centre) with two leaves on
  // top - the silhouette people actually associate with the Pi.
  static const String raspberryPi = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <!-- Leaves -->
  <path d="M12 8c-1-3-3.5-3.6-5-3 .3 1.6 1.6 3.4 4 3.5"
        fill="currentColor"/>
  <path d="M12 8c1-3 3.5-3.6 5-3-.3 1.6-1.6 3.4-4 3.5"
        fill="currentColor"/>
  <!-- Berry cluster -->
  <circle cx="12" cy="12" r="2.4" fill="currentColor"/>
  <circle cx="8.6" cy="13.6" r="2.4" fill="currentColor"/>
  <circle cx="15.4" cy="13.6" r="2.4" fill="currentColor"/>
  <circle cx="10.2" cy="17.0" r="2.4" fill="currentColor"/>
  <circle cx="13.8" cy="17.0" r="2.4" fill="currentColor"/>
</svg>
''';

  // ── Arch Linux - chevron silhouette ────────────────────────────
  // Filled "A" silhouette - instantly recognisable as Arch.
  static const String arch = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M12 2L3 21h3.2l1.3-3h9l1.3 3H21L12 2zm-3.2 13l3.2-7.5L15.2 15H8.8z"
        fill="currentColor"/>
</svg>
''';

  // ── Alpine Linux - two mountain peaks ──────────────────────────
  static const String alpine = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M2 19l5.5-9 4 5.5 2.5-3.5L22 19H2z" fill="currentColor"/>
  <circle cx="17" cy="6" r="1.8" fill="currentColor" opacity="0.6"/>
</svg>
''';

  // ── FreeBSD - Beastie head simplified ──────────────────────────
  // Round face with two horns; dark dot eyes.
  static const String freebsd = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <circle cx="12" cy="14" r="7" fill="currentColor"/>
  <path d="M7 9L4 4M17 9l3-5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
  <circle cx="9.5" cy="13" r="0.9" fill="#0A0A0A"/>
  <circle cx="14.5" cy="13" r="0.9" fill="#0A0A0A"/>
  <path d="M10 16.5q2 1.5 4 0" stroke="#0A0A0A" stroke-width="1.2" fill="none" stroke-linecap="round"/>
</svg>
''';

  // ── Container / Docker - whale silhouette (simplified) ─────────
  // We can't reproduce the Moby whale exactly without Docker's
  // permission, but the stacked-container + ocean wave silhouette
  // is the universal "container" mark.
  static const String container = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <rect x="3" y="9" width="3" height="3" fill="currentColor"/>
  <rect x="6.5" y="9" width="3" height="3" fill="currentColor"/>
  <rect x="10" y="9" width="3" height="3" fill="currentColor"/>
  <rect x="13.5" y="9" width="3" height="3" fill="currentColor"/>
  <rect x="6.5" y="5.5" width="3" height="3" fill="currentColor"/>
  <rect x="10" y="5.5" width="3" height="3" fill="currentColor"/>
  <rect x="10" y="2" width="3" height="3" fill="currentColor"/>
  <path d="M2 14c1 2 3 3.5 7 3.5h6c3 0 5-1.2 6.5-3.5L22 13c-.6 1-2.2 2-4 2H6c-1.6 0-3-1-4-2v1z"
        fill="currentColor"/>
</svg>
''';

  // ── NixOS - snowflake / lambda cluster ─────────────────────────
  // Six elongated lambda arms radiating from centre.
  static const String nixos = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <g stroke="currentColor" stroke-width="2.2" stroke-linecap="round">
    <path d="M12 4l3 5"/><path d="M12 4l-3 5"/>
    <path d="M19 8.5l-3 5"/><path d="M19 8.5l-5.5.3"/>
    <path d="M19 15.5l-5.5-.3"/><path d="M19 15.5l-3-5"/>
    <path d="M12 20l3-5"/><path d="M12 20l-3-5"/>
    <path d="M5 15.5l3-5"/><path d="M5 15.5l5.5-.3"/>
    <path d="M5 8.5l5.5.3"/><path d="M5 8.5l3 5"/>
  </g>
</svg>
''';

  // ── Home Assistant - house with H ──────────────────────────────
  static const String homeAssistant = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M12 2.5L2 11h2.5v9h15v-9H22L12 2.5z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>
  <path d="M9 12v6M15 12v6M9 15h6" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>
</svg>
''';

  // ── Fedora - infinity / chord ──────────────────────────────────
  // Stylised "f" bubble - Fedora's wordless mark.
  static const String fedora = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <circle cx="12" cy="12" r="9" fill="currentColor"/>
  <path d="M14 6h-2.5a2.5 2.5 0 0 0-2.5 2.5V11H7v2h2v5h2v-5h2.2v-2H11V8.7c0-.4.3-.7.7-.7H14V6z"
        fill="#FFFFFF"/>
</svg>
''';

  // ── Linux Mint - text "Mint" with leaf ─────────────────────────
  static const String mint = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <rect x="2.5" y="5" width="19" height="14" rx="2" fill="currentColor"/>
  <path d="M6 8v8M6 8h3.5l1.5 4 1.5-4H16v8M16 16V10" stroke="#FFFFFF" stroke-width="1.4" fill="none" stroke-linecap="round"/>
</svg>
''';

  // ── Generic terminal fallback (unknown OS) ─────────────────────
  static const String terminal = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <rect x="2.5" y="4" width="19" height="16" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.6"/>
  <path d="M6 9l3 3-3 3M11 16h6" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
</svg>
''';

  // ── Pop!_OS - circular orbit ───────────────────────────────────
  static const String pop = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <circle cx="12" cy="12" r="9" fill="currentColor"/>
  <text x="12" y="16" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="700" fill="#0A0A0A">P!</text>
</svg>
''';

  // ── Kali Linux - dragon head silhouette (simplified) ───────────
  static const String kali = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M3 5l5 4-3 1 4 3-2 1 4 2-1 1 4 1-1 2 6-3v-1l-3 1 1-2-3 1 1-2-3 1 1-2-4 1 2-2-4 0 2-2-3-1 3-1-1-2z"
        fill="currentColor"/>
</svg>
''';

  // ── TrueNAS - TN cube ─────────────────────────────────────────
  static const String truenas = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M3 7l9-4 9 4-9 4-9-4z" fill="currentColor"/>
  <path d="M3 7v10l9 4V11L3 7z" fill="currentColor" opacity="0.7"/>
  <path d="M21 7v10l-9 4V11l9-4z" fill="currentColor" opacity="0.5"/>
</svg>
''';

  // ── Unraid - checkerboard array ────────────────────────────────
  static const String unraid = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <rect x="3" y="6" width="3" height="3" fill="currentColor"/>
  <rect x="3" y="10.5" width="3" height="3" fill="currentColor"/>
  <rect x="3" y="15" width="3" height="3" fill="currentColor"/>
  <rect x="7.5" y="10.5" width="3" height="3" fill="currentColor"/>
  <rect x="12" y="6" width="3" height="3" fill="currentColor"/>
  <rect x="12" y="10.5" width="3" height="3" fill="currentColor"/>
  <rect x="12" y="15" width="3" height="3" fill="currentColor"/>
  <rect x="16.5" y="6" width="3" height="3" fill="currentColor"/>
  <rect x="16.5" y="15" width="3" height="3" fill="currentColor"/>
</svg>
''';

  // ── ESXi - VM stack ───────────────────────────────────────────
  static const String esxi = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <rect x="3" y="4" width="18" height="5" rx="0.5" fill="currentColor"/>
  <rect x="3" y="10" width="18" height="5" rx="0.5" fill="currentColor" opacity="0.7"/>
  <rect x="3" y="16" width="18" height="4" rx="0.5" fill="currentColor" opacity="0.5"/>
</svg>
''';

  // ── openSUSE - chameleon silhouette ────────────────────────────
  static const String openSuse = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M6 14c0-3 2-5 5-5s5 2 5 5-2 5-5 5h-3c-1.1 0-2-.9-2-2v-3z" fill="currentColor"/>
  <path d="M11 9c-1-2-1-3 0-5 1 1.5 1 3 0 5z" fill="currentColor"/>
  <circle cx="13.5" cy="13" r="0.8" fill="#FFFFFF"/>
</svg>
''';

  // ── CentOS - quadrant flower ───────────────────────────────────
  static const String centos = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <path d="M12 2v8H4l8-8z" fill="currentColor"/>
  <path d="M12 2l8 8h-8V2z" fill="currentColor" opacity="0.85"/>
  <path d="M12 22v-8h8l-8 8z" fill="currentColor" opacity="0.7"/>
  <path d="M12 22l-8-8h8v8z" fill="currentColor" opacity="0.55"/>
</svg>
''';
}
