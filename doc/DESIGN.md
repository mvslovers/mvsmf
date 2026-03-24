# Design System Document: The Sovereign Console

## 1. Overview & Creative North Star
### Creative North Star: "The Architectural Curator"
Mainframe management is often synonymous with visual clutter and archaic terminal emulation. This design system rejects the "retro-tech" aesthetic in favor of **Architectural Curation**. It treats complex data as a high-end editorial layout—clean, authoritative, and spacious. 

We move beyond the "grid of boxes" by utilizing **Intentional Asymmetry** and **Tonal Depth**. Instead of cramming information, we use wide margins and varying surface elevations to guide the administrator’s eye. The goal is to make managing a mainframe feel as fluid and premium as navigating a modern architectural portfolio.

---

## 2. Colors: Tonal Authority
Our palette moves away from standard "Admin Blue" into deep, sophisticated charcoals and precision teals.

### The Palette
- **Primary (`#00488d`):** Used sparingly for high-intent actions.
- **Tertiary/Accents (`#005151`):** A sophisticated teal reserved for "System Health" and success states.
- **Surface Hierarchy:** 
    - `surface`: The base canvas (#f8f9fb).
    - `surface-container-low`: Secondary navigation or sidebars.
    - `surface-container-lowest`: The "Paper" layer—where primary data lives.

### The "No-Line" Rule
**Borders are a design failure.** To achieve a high-end feel, designers are prohibited from using 1px solid strokes to separate sections. 
- Define boundaries through **background color shifts**. Use `surface-container-low` for a sidebar sitting against a `surface` main content area.
- Use **Vertical White Space** (Tokens `8` through `16`) to create mental separation.

### The "Glass & Gradient" Rule
For high-level global actions or floating command bars, use **Glassmorphism**:
- Background: `surface` at 70% opacity.
- Effect: `backdrop-blur: 12px`.
- CTA Gradients: Use a linear gradient from `primary` (#00488d) to `primary-container` (#005fb8) at 135 degrees to give buttons a "jeweled" tactile depth.

---

## 3. Typography: Editorial Hierarchy
We utilize a dual-typeface system to balance "High-End Magazine" headers with "Technical Precision" data.

- **Display & Headlines (Manrope):** A modern geometric sans-serif used for page titles and high-level KPIs. It provides the "Architectural" feel.
- **Body & Labels (Inter):** Chosen for its exceptional legibility in dense data environments (tables and logs).
- **The Contrast Strategy:** Pair a `headline-lg` (Manrope, Semibold) with a `label-sm` (Inter, Medium, All-Caps) to create an authoritative, structured look.

---

## 4. Elevation & Depth: Tonal Layering
We do not use drop shadows to show hierarchy; we use **Physicality**.

### The Layering Principle
Think of the UI as stacked sheets of fine material.
1. **Level 0 (Base):** `surface` (#f8f9fb).
2. **Level 1 (Inlay):** `surface-container-low` (#f2f4f6) – used for recessed areas like search bars or inactive panels.
3. **Level 2 (The Sheet):** `surface-container-lowest` (#ffffff) – the primary focus area for data tables.

### Ambient Shadows
When an element must "float" (e.g., a Modal or Command Palette), use an **Ambient Shadow**:
- `box-shadow: 0 20px 40px rgba(25, 28, 30, 0.06);`
- The shadow must be tinted with `on-surface` (#191c1e) at extremely low opacity to mimic natural light.

### The Ghost Border Fallback
If contrast ratios require a boundary, use a **Ghost Border**:
- `outline-variant` (#c2c6d4) at 20% opacity. Never use 100% opaque borders.

---

## 5. Components: Precision Primitives

### Data Tables (The Core)
- **Container:** Use `surface-container-lowest` background.
- **Header:** `label-md` in `on-surface-variant`. No vertical dividers.
- **Rows:** Use `spacing-4` for vertical padding. Separate rows with a subtle `surface-variant` background shift on hover.
- **Status:** Use a "Pill" style with `tertiary-container` for active jobs—minimal and clean.

### File Explorers
- **Structure:** Indentation should follow the `spacing-3` scale.
- **Selection:** Use `primary-fixed` (#d6e3ff) with a left-accented vertical bar (4px) to show the active dataset. Do not outline the entire row.

### Log Viewers & Syntax
- **Background:** Use `inverse-surface` (#2d3133) for high-contrast technical reading.
- **Syntax:** 
    - Commands: `tertiary-fixed` (#93f2f2)
    - Errors: `error` (#ba1a1a)
    - Strings: `primary-fixed-dim` (#a8c8ff)

### Buttons
- **Primary:** Gradient-filled (Primary to Primary-Container), `rounded-md` (0.375rem).
- **Secondary:** Transparent background with a `Ghost Border`.
- **Tertiary:** Text-only, using `on-surface-variant`.

### Inputs & Text Areas
- Use `surface-container-high` for the input track. 
- Transition to a `primary` 2px bottom-border only on focus to maintain the "No-Line" philosophy.

---

## 6. Do’s and Don'ts

### Do:
- **Use "Breathing Room":** If you think there is enough margin, add 20% more. High-end systems feel expensive because they aren't crowded.
- **Tonal Transitions:** Transition between `surface-container` levels to define app regions.
- **Monospace for Data:** Use Inter's tabular numbers feature or a dedicated mono font for memory addresses and hex codes.

### Don't:
- **Don't use 3270 Green:** Avoid high-contrast neon greens or "terminal" fonts. This is a modern enterprise console, not an emulator.
- **Don't use Heavy Dividers:** Avoid solid 1px lines. They create visual noise.
- **Don't use Default Shadows:** Never use `rgba(0,0,0,0.5)`. Shadows must be large, soft, and tinted.
- **Don't use Sharp Corners:** Follow the `roundedness-md` (0.375rem) as a baseline to soften the industrial nature of mainframe data.