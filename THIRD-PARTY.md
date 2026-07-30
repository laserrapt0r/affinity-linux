# Third-party components

This repository is [MIT licensed](LICENSE) and bundles no third-party code.
Everything below is fetched from its own upstream at build or run time and keeps
its own licence. Nothing here is redistributed by this repository.

| Component | Licence | Obtained |
|---|---|---|
| [Wine](https://www.winehq.org/) | LGPL-2.1-or-later | WineHQ apt repository, at image build |
| [DXVK](https://github.com/doitsujin/dxvk) | Zlib | GitHub release, at image build |
| [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) | LGPL-2.1-or-later | GitHub release, at image build |
| [AffinityPluginLoader](https://github.com/noahc3/AffinityPluginLoader) | MIT | GitHub release, at image build |
| WineFix (APL plugin) | GPL-2.0 | same release archive |
| `d2d1.dll` shipped with WineFix | LGPL-2.1 | same release archive |
| [winetricks](https://github.com/Winetricks/winetricks) | LGPL-2.1 | pinned raw file, at image build |
| Microsoft .NET Framework 4.8 | proprietary, Microsoft redistributable | Microsoft servers, via winetricks |
| Microsoft Visual C++ runtime | proprietary, Microsoft redistributable | Microsoft servers, via winetricks |
| Mesa, Vulkan loader, GStreamer, fonts | various (MIT / LGPL / Apache-2.0) | Ubuntu archive, at image build |
| **Affinity** | **proprietary — Canva** | vendor download, at **first run** |

## On licence compatibility

MIT is the appropriate choice for this repository precisely *because* nothing is
vendored. The GPL-2.0 licence on WineFix would matter if these files shipped or
linked against it; they do not. A built image ends up holding software under
several licences side by side, which is mere aggregation rather than a combined
work — these scripts install and invoke those components, they neither link
against nor derive from them.

Choosing a copyleft licence for the scripts would only have created a needless
friction point with that GPL-2.0-only component, for no practical gain on what
amounts to a build recipe.

## Affinity

Affinity is proprietary software belonging to Canva. The image deliberately does
**not** contain it: it is downloaded from the vendor into a data volume on first
run, under the vendor's own terms. You need whatever licence or account Canva
requires in order to use it. This also means the image itself can be published
and rebuilt freely.
