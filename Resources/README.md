# App icon

`AppIcon.png` is the master artwork, generated with the built-in OpenAI ImageGen tool. It contains alpha transparency outside the macOS rounded-square tile. No external brand assets are used.

`Assets.xcassets/AppIcon.appiconset` contains the standard and Retina macOS icon sizes derived from the master artwork. Xcode compiles the asset catalog and includes the application icon automatically. Edit the AppIcon set in Xcode when changing the icon; keep the master artwork above in sync. No icon-generation script is required for building or running the app.

Final generation prompt:

> Use case: logo-brand. Create a production macOS application icon for Tracking Inspector, a local developer tool for inspecting analytics events arriving from multiple iPhones. One square 1024x1024 PNG asset with genuine transparent background outside the icon. A centered macOS rounded-square tile, with normal macOS icon margins (tile about 84 percent of canvas width), rich teal and turquoise enamel surface, restrained soft dimensional bevel and a subtle shadow. The single bold central glyph is a white circular inspection lens / radar ring enclosing three small connected event nodes, with a short magnifier handle pointing lower right. The connected nodes suggest a trace of events; keep geometry extremely clean and high contrast, recognizable at 32px, generous negative space. Polished native macOS utility icon, front view, no perspective, no text, no letters, no watermark, no extra objects, no mockup, no background scene. Palette should harmonize with the existing app's turquoise-teal accent #168f92 and white UI. Output only the icon artwork.
