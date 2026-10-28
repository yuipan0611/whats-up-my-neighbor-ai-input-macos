---
name: "What's up my neighbor — Remote agent preview"
description: "A native macOS task panel that keeps local demonstration visibly distinct from remote execution."
colors:
  secondary-light: "rgb(36%, 36%, 36%)"
  secondary-dark: "rgb(74%, 74%, 74%)"
  error-light: "rgb(72%, 12%, 10%)"
  error-dark: "rgb(100%, 58%, 55%)"
typography:
  headline:
    fontFamily: "-apple-system, system-ui"
    fontWeight: 600
  body:
    fontFamily: "-apple-system, system-ui"
    fontWeight: 400
  callout:
    fontFamily: "-apple-system, system-ui"
    fontWeight: 400
spacing:
  related: "12pt"
  compact: "10pt"
  event: "9pt"
---

# Design System: Remote agent preview

## Overview

**Creative North Star: "The native task panel"**

This is a narrow extension of the existing macOS product: the approved black cat, system typography, semantic surfaces and native controls supply its identity. The panel stays quiet enough to read a task and its chronological activity without decorative containers.

Its visual hierarchy continually identifies this as a local demonstration. Provider names are labels awaiting remote verification; the interface does not establish live SSH, provider login or remote capability. This document describes only the standalone preview, not a shipped production feature.

**Key Characteristics:**
- Existing black cat and Traditional Chinese interface copy.
- Stable environment rail beside a scrollable task workspace.
- Native controls and appearance-aware neutral surfaces.
- Explicit demonstration, progress, cancellation, failure and result states.

## Colors

A restrained neutral palette delegates surfaces and ordinary controls to macOS. The frontmatter records only the repeated custom foreground overrides, preserving the calibrated source values as CSS percentages.

### Neutral
- **Secondary light / dark:** explanatory copy, provider metadata, placeholders and event symbols. `PreviewPalette.secondary` chooses the corresponding frontmatter token from the current Aqua or Dark Aqua appearance.
- **Native surfaces:** the rail uses `NSColor.windowBackgroundColor`; the workspace uses `NSColor.textBackgroundColor`; the demonstration capsule uses `NSColor.controlBackgroundColor`. Text and divider strokes retain native semantic colors. These are dynamic AppKit roles, not fixed web hex values.

### Semantic status
- **Error light / dark:** `PreviewPalette.error` supplies the corresponding appearance token to error labels and the over-limit character count. Failure also has a warning symbol and explicit text.
- The submit button uses SwiftUI's `.borderedProminent` style with the system's current control treatment; no custom accent hue is established.

**The Semantic Surface Rule.** Preserve AppKit surface roles and the paired appearance overrides; do not freeze a sampled screenshot color into a new palette.

The finish review reported contrast of 5.02:1 for light secondary text, 5.62:1 for light error text and 10.07:1 for dark secondary text. These are the supplied review measurements, not a guarantee for every system appearance or future background.

## Typography

**Body and control font:** macOS system font with the system's Traditional Chinese fallback. There is no separate display family.

Headings use SwiftUI `.headline`; task text uses `.body`; supporting labels and activity use `.callout`. The page title is a local fixed-size exception (26pt, semibold), followed by `.title3` with medium weight. The character counter uses `.caption`. Native text roles, rather than a fabricated web size ramp, remain authoritative.

**The Native Type Rule.** Extend this desktop surface with semantic system text roles; preserve the title's modest hierarchy and readable explanatory copy.

## Layout

A fixed environment rail (220pt) and divider sit beside one vertical scroll view. The main stack spaces sections by 24pt and uses 28pt inset; the rail uses 20pt inset. Related groups repeatedly use the frontmatter's compact and related spacing. Events align a 16pt symbol column with wrapping text.

The window opens at 980 × 740pt and has a 760 × 620pt content minimum. The rail remains visible as the window narrows; the main content wraps and scrolls instead of switching to a mobile layout. The compact dark capture uses 760 × 680pt. Long supporting copy and results are allowed to grow vertically.

## Elevation & Depth

The custom view adds no shadows, gradients or floating cards. Native background roles, thin dividers and control surfaces establish depth. macOS owns button, picker, editor and focus treatment; render fixtures may show inactive controls differently from an active window.

## Shapes

The editor's thin separator-color outline has a restrained rounded rectangle (6pt corner radius). The demonstration indicator uses a capsule with horizontal 10pt and vertical 6pt padding. Buttons and the picker keep their native geometry. The approved cat icon is displayed at 36 × 36pt without introducing a new mascot treatment.

## Components

- **Environment rail:** groups identity, local/VPS status and provider selection; a bottom disclosure keeps the standalone boundary visible. It is contextual information, not a working remote connection navigator.
- **Provider picker:** uses native selection and an explicit accessibility label stating that all three providers await remote verification. Selection is disabled during a task. Only this preview's provider preference is persisted.
- **Task editor:** native `TextEditor`, 92pt content height, explicit accessibility label and noninteractive placeholder. The placeholder and cat image are hidden from accessibility. Example fill is disabled during a task.
- **Actions:** submit uses native prominent styling and Command–Return. It is enabled only for nonblank input of at most 5,000 characters while idle. Running exposes cancellation with the cancel keyboard action; the editor and provider selection are disabled until the task ends.
- **Demonstration indicator:** persistent text and information symbol identify the execution boundary; the capsule is informational, not an interactive chip.
- **Activity:** the empty state explains where a task will appear. Running shows a determinate progress bar and chronological messages; completed retains progress and shows selectable result text. Cancelled and failed remove the progress bar and expose a readable next step or failure message. Decorative event symbols are hidden from accessibility; progress has an explicit label.
- **Keyboard and editing:** standard AppKit edit-menu commands support undo, cut, copy, paste and select all. No custom focus ring or hover animation is added. Closing the standalone app cancels its task.

The six supplied captures cover ready, running, cancelled, failed, completed and compact dark layouts. They are fixture renders of this app's view tree. They do not prove a live remote operation, interactive VoiceOver acceptance or the active-window focus appearance.

## Do's and Don'ts

### Do:
- **Do** reuse the approved cat, native control styling and Traditional Chinese wording.
- **Do** keep demonstration status and provider verification limits visible alongside the task workflow.
- **Do** pair state color with text or a symbol, preserve keyboard commands and allow supporting text to wrap.
- **Do** test both appearances and the minimum desktop width when changing this panel.

### Don't:
- **Don't** present a provider selection, fixture result or completed demonstration as verified remote capability.
- **Don't** replace semantic macOS surfaces with screenshot-derived fixed colors or add a new accent identity.
- **Don't** turn this preview's task layout into a production-wide or mobile design requirement.

Not canonized: no identified visual defect remains in the supplied finish verdict. Browser-only component CSS, invented tonal ramps and live remote-success styling are deliberately absent because this native build supplies no evidence for them.
