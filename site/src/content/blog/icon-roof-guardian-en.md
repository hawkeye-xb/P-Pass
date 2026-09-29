---
title: How we designed the P-Pass app icon, from first sketch to a size-specific icon set
date: 2026-08-10
tags: [design, icons]
lang: en
draft: true
---

The P-Pass icon is a roof guardian. On traditional Chinese buildings, a row of small clay or ceramic animal figures sits along the roof ridge, and folk belief holds that they watch over the house. Ours is built from two letter Ps facing each other: the curves of the Ps are the eyes, two horns sweep outward, and a lightning bolt in the middle of the mouth sits exactly on the vertical center line of the canvas.

It took nine rounds of iteration, with drafts lettered A through P, and at the end we still had to give ground on size. This post describes the process as it happened, including the ideas we threw out.

## Round one: starting from an emoticon

The product is called P-Pass, and the name reads as an emoticon: the two Ps look like a pair of eyes. The first design took that literally. It was a cat face with green pupils: two round eyes, with the hyphen in P-P doubling as the nose.

![Round one: cat eyes with green pupils](/icons/drafts/a.svg)

The pupils use the only green in our palette, `safe #2E6B4F`. In the product, that green means exactly one thing: "stored safely." Green cat eyes say "everything is backed up." That idea survived from the first round to the final icon.

## The middle rounds: feeling it out

B was a wink, C was a night patrol, D was a plain wordmark. E and F tried a nose shadow joined to a mouth and a two-eyes-plus-mouth layout, and G connected the mouth into one line. All of these were looking for a face, and none of them got there. An icon has to be recognizable at about a centimeter across, and looking nice isn't enough for that.

## Wrong turn one: the dotted line

Partway through, our product lead had a new idea. Since the right half is a mirror image, make it "dashed." The solid left half is the computer at home, the dashed right half is the phone out in the world, and a small lightning bolt in the middle of the mouth joins the two. The picture is the moment the phone connects to the home computer and sends the photos back.

The concept was accepted on the first pass. The first way of drawing it died fast. Our product lead, who had proposed the idea, rejected the dotted-line version the same day it went up, saying the dots looked "a bit gross."

![Dotted-line version: rejected](/icons/drafts/l.svg)

After that, the "dashed" half was drawn three more ways: short dashes, a lighter ink tone, and finally a carbon-fiber diagonal weave. Looking back, we should have reviewed the concept and the rendering separately. "Solid left, dashed right, lightning in the center" lasted from the day it was proposed to the final design. The only thing rejected was one rendering, the dotted line.

## Wrong turn two: a cramped face

Once the roof guardian version existed, the problem was **spacing**. In the first cut (J0), the gap between the eyes and the mouth was only 12 units. The face looked cramped, with the eyes and mouth almost touching, as if someone were pinching it.

![First cut: 12 units of clearance](/icons/drafts/j0.svg)

The revision (J) changed the spacing rule so that whitespace follows the same rhythm as the strokes: the clearance from the outer edge of the eye ring to the mouth line grew to exactly one stroke width (72). With the mouth line at 75% of the face height and the eye centers at 47%, the cramped look went away and the face looked steadier.

![Revision: 72 units of clearance](/icons/drafts/j.svg)

That spacing rule went into the design spec: **clearance between features ≥ one stroke width**. You can check it with a ruler. Measure from the outer edge of the eye ring to the mouth line, and you know right away whether it's at least 72.

## A third option: carbon weave

The later tone version (O) tried a different approach: the whole right half switched to light ink, and the lightning bolt split its color strictly at its midpoint. It was clean, but our product lead suggested a new direction: a carbon-fiber texture.

That produced the carbon weave version (P). The strokes in the right half are filled with 45° diagonal stripes alternating between ink and transparent, 36 wide with 32 gaps. The lightning bolt still splits color at its midpoint, and the half on the dashed side is striped too.

![Carbon weave version](/icons/drafts/p.svg)

At large sizes the texture reads clearly, but below 40px the stripes blur into a half gray. The design notes say only one thing about this: at that size it visually falls back to the look of the O tone version, which is acceptable.

## Giving ground on size: one icon wasn't enough

In the end we kept three versions of the icon, each assigned to a range of sizes:

- **Carbon weave version** (main icon): the app icon on macOS and Android, and the launch screen. Our product lead picked this one.
- **Tone version**: a backup for small and medium sizes where the stripes don't work well.
- **All-solid roof guardian version**: the tray icon, the favicon, and the small notification icon. At 16px the stripes turn into a gray blob, so it has to be solid.

All three versions are the same face. The carbon weave and tone versions differ only in how the right-half strokes are filled. The all-solid version uses solid ink on both sides, and its mouth is a straight line with no lightning bolt in the middle.

## The final design: the split point is on the center line

The final version makes the split geometrically exact. The canvas is 1024×1024, and the diagonal in the middle of the lightning bolt passes exactly through the point where the vertical center line meets the mouth line, (512, 768). The color changes at that point. The left half is ink, the right half is striped, the cut is perpendicular to the diagonal, and the solid side no longer crosses over at all.

Every number can be checked by a script: stroke width 72, eye ring r=146, the coordinates of the four lightning segments, and a weave period of 68. Someone else holding this set of numbers could draw the same icon. The source files (SVG, every draft, and the spec) are in the repository:

- Process gallery: [drafts-gallery.html](https://github.com/hawkeye-xb/P-Pass/blob/main/docs/design/2026-08-11-icon-v1/drafts-gallery.html)
- Final design: [icon-v1 spec](https://github.com/hawkeye-xb/P-Pass/blob/main/docs/design/2026-08-11-icon-v1/README.md)
