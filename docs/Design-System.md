# Design System

**Tokens** (`Design/Theme.swift`): spacing 4/8/12/16/24/32, page margin 28; radii card 16, control 10, chip 7. Brand gradient teal → blue. Section tints: clean (green-teal), storage (blue-violet), apps (violet-pink), performance (orange-pink), tools (slate), plus warning, danger and success. Every colour is used as a gradient on icons and rings and at ≤ 18% opacity for washes, so light and dark mode both come from system surfaces (`controlBackgroundColor`, `windowBackgroundColor`).

**Components:** `Page` (header with IconBadge, title, subtitle, actions), `Card`/`cardSurface`, `Metric` (rounded numerals with numeric transitions), `Ring`, `Sparkline`, `SizeBar`, `Pill`/`RiskPill`, `ChipPicker`, `EmptyHero`, `ScanProgress` (determinate only when a real total exists), `SelectionBar`, `ReviewSheet`, `ReportBanner`, `Treemap`, `HoverLift`.

**Motion:** `Motion.standard` (0.35 s smooth), `.gentle`, `.spring`; all `nil` when Reduce Motion is on. No continuous animations: a pulsing icon and blurred backgrounds were removed after they measured 32% CPU.

**Sound:** 14 original synthesised cues (soft inharmonic bells, glides, ticks), −6 dBFS peak. On by default (can be turned off), volume setting, silent when the system UI-sound setting is off.

**Modes:** Basic shows names and plain-language consequences. Expert adds full paths, rule IDs, modified dates, hashes, device nodes, MAC/IPv6/MTU and disk-image targets.
