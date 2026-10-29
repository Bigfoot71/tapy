# tapy

tapy is a small tool for designing convolution kernels.

Set the taps on the grid their weights by hand or with automatic distributions, and preview the result on your own image. The kernel is exported as a GLSL function.

## Editing

- Drag and drop an image onto the window to replace the default one.
- Left click on the grid toggles a tap, right click selects it so you can type its weight.
- Weights can be distributed automatically (uniform or gaussian) and normalized.
- Both previews can be zoomed with the mouse wheel and panned.
- The result keeps transparency.

## Linear mode

By default taps sit on texel centers and the image is sampled with nearest filtering.

Enabling linear mode subdivides the grid into halves or quarters of a texel, so taps can be placed at fractional offsets.

## GLSL export

The kernel is exported as an unrolled `vec4 convolve(sampler2D, vec2, vec2)` function, with one line per tap and zero-weight taps skipped.

## Try it online

- => https://bigfoot71.github.io/demos/tapy/app/

## Credits

The default image is a photograph by Leonhard Niederwimmer, available on [Unsplash](https://unsplash.com/photos/a-very-tall-building-with-some-very-big-pillars-2lArT4Ja4Ew).
