# SDL3 Graphics Project Template Plugin

This plugin adds an `SDL3 Graphics + CMake` template to TinaIDE's New Project flow.

The template targets the Registry P0 graphics package set:

- SDL3
- SDL3_image
- SDL3_ttf
- Box2D
- miniaudio

The sample renders with SDL primitives, initializes SDL3_ttf, verifies SDL3_image and miniaudio headers, and uses Box2D to drive a moving rectangle. It does not require image, font, or audio assets on first run.

## Package

PowerShell:

```powershell
Compress-Archive -Path .\* -DestinationPath ..\tinaide.template.sdl3.graphics.tinaplug
```

## Install

TinaIDE -> Settings -> Plugins -> Install from file

Select `tinaide.template.sdl3.graphics.tinaplug`.
