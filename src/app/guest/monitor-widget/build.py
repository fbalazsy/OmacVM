#!/usr/bin/python3
"""Build omacvm.monitor: Omarchy's display panel plus OmacVM.app's switch.

    build.py OUT_DIR [OMARCHY_MONITOR_DIR]

Copies Omarchy's own display widget (/usr/share/omarchy/shell/plugins/panels/
monitor) into OUT_DIR, so it follows the installed Omarchy, and adds a "MAC
DISPLAYS" section with "Use external displays" (omacvm-displays external
toggle), and on a display 4K wide or more a line under the scale presets: 2x
is the sharp one there. In "Full screen including notch" every one of
Omarchy's scale presets on that output, set through `omacvm-displays scale`
(the Mac gives the output a size that fits it first, #355). Omanotch's hidden NOTCH output is left out of its
display list (Omanotch's patch, src/omanotch/guest/monitor/display-panel.py).
OUT_DIR gets this folder's manifest.json and placement.sh and a
.source-sha256 stamp of the panel it was built from. Exit 1 when Omarchy's
panel has changed so much that the switch no longer fits: then the stock
widget stays.
"""

import hashlib
import importlib.machinery
import importlib.util
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_SOURCE = "/usr/share/omarchy/shell/plugins/panels/monitor"
# Omanotch's patch that leaves its hidden NOTCH output out (same copy of src/).
NOTCH_PATCH = HERE.parents[2] / "omanotch/guest/monitor/display-panel.py"

PROPS = """
  // OmacVM.app: in full screen, Omarchy on every Mac display (omacvm-displays).
  property bool macDisplays: false
  property bool macExternal: true
  // OmacVM.app: the output in "Full screen including notch" ("" otherwise).
  property string macFullPanel: ""
  // OmacVM.app: the focused display's width, for the scale hint below.
  readonly property int macFocusedWidth: {
    for (var i = 0; i < displays.length; i++)
      if (displays[i] && displays[i].focused) return displays[i].width
    return 0
  }
"""

FUNCS = """
  // ---- OmacVM.app: the Mac's external displays ----
  function toggleMacExternal() {
    root.macExternal = !root.macExternal
    macToggleProc.command = ["omacvm-displays", "external", root.macExternal ? "on" : "off"]
    if (!macToggleProc.running) macToggleProc.running = true
  }

  Process {
    id: macStateProc
    command: ["omacvm-displays", "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = String(text || "").trim()
        root.macDisplays = state === "on" || state === "off"
        if (root.macDisplays) root.macExternal = state === "on"
      }
    }
  }

  // ---- OmacVM.app: independent secondary zoom and full-panel sizing ----
  function macScaleManagedFocused() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return (root.macFullPanel !== "" && display.name === root.macFullPanel)
          || (display.name !== "Virtual-1" && /^Virtual-[1-9][0-9]*$/.test(display.name))
    }
    return false
  }

  Process {
    id: macFullPanelProc
    command: ["omacvm-displays", "fullpanel"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.macFullPanel = String(text || "").trim()
    }
  }

  Process {
    id: macToggleProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running && !macStateProc.running) macStateProc.running = true
  }

"""

SECTION = """          // ---------- OmacVM.app: Mac displays ----------
          PanelSeparator {
            visible: root.macDisplays
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.macDisplays

            PanelSectionHeader {
              text: "MAC DISPLAYS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            CursorSurface {
              id: macExternalRow
              width: panelColumn.width
              hasCursor: root.cursorActive && root.focusSection === "mac"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(macExternalRow)
              foreground: root.bar.foreground
              fill: Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)
              implicitHeight: macExternalInner.implicitHeight + Style.spacing.xl

              Row {
                id: macExternalInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Text {
                  text: "󰍺"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  width: Style.space(22)
                  horizontalAlignment: Text.AlignHCenter
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    text: "Use external displays"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.macExternal ? "Full screen fills every Mac display"
                                           : "Full screen stays on one Mac display"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.macExternal ? "󰄬" : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.subtitle
                  width: Style.space(14)
                  horizontalAlignment: Text.AlignRight
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "mac"
                  root.selectedIndex = 0
                }
                onClicked: root.toggleMacExternal()
              }
            }
          }

"""

# Under the scale presets on a 4K or larger display: whole scales are the sharp
# and light ones there (docs/troubleshooting.md, finding 24).
SCALE_HINT = """          // ---------- OmacVM.app: which scale suits a 4K or 5K display ----------
          Text {
            visible: root.macFocusedWidth >= 3840
            width: parent.width
            leftPadding: Style.space(6)
            rightPadding: Style.space(6)
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "2x is the sharpest here. In-between scales look softer in some apps and use more GPU memory."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

"""

# Omarchy's colours as Commons.Color: on Qt 6.12 a bare Color is QtQuick's
# own (#376). Omarchy's panel imports the alias itself from about October 2026.
COMMONS = "import qs.Commons\n"
COMMONS_ALIAS = "import qs.Commons as Commons\n"

# (anchor, replacement): every anchor must be found exactly once.
EDITS = [
    # Keep normal primary/non-VM scaling under Omarchy's original policy.
    ('    actionProc.command = ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]\n',
     '    actionProc.command = root.macScaleManagedFocused() ? ["/usr/local/bin/omacvm-displays", "scale", String(scale)]\n'
     '      : ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]\n'),
    ("  property int enabledDisplayCount: 0\n",
     "  property int enabledDisplayCount: 0\n" + PROPS),
    ('    if (displays.length > 1) list.push("monitors")\n',
     '    if (displays.length > 1) list.push("monitors")\n'
     '    if (macDisplays) list.push("mac")\n'),
    ('    if (section === "monitors") return displays.length\n',
     '    if (section === "monitors") return displays.length\n'
     '    if (section === "mac") return 1\n'),
    ('    return section === "brightness" || section === "textsize" || section === "scale"\n',
     '    return section === "brightness" || section === "textsize" || section === "scale" || section === "mac"\n'),
    ('    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {\n',
     '    if (focusSection === "mac") {\n'
     '      toggleMacExternal()\n'
     '      return\n'
     '    }\n'
     '    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {\n'),
    ("    if (!stateProc.running) stateProc.running = true\n",
     "    if (!stateProc.running) stateProc.running = true\n"
     "    if (!macStateProc.running) macStateProc.running = true\n"
     "    if (!macFullPanelProc.running) macFullPanelProc.running = true\n"),
    ("  BarIconButton {\n    id: button\n",
     FUNCS + "  BarIconButton {\n    id: button\n"),
    ("          // ---------- Monitors ----------\n",
     SCALE_HINT + "          // ---------- Monitors ----------\n"),
    ("          Item {\n            width: parent.width\n            height: Style.space(4)\n          }\n",
     SECTION + "          Item {\n            width: parent.width\n            height: Style.space(4)\n          }\n"),
]


# Every one of Omarchy's scales in "Full screen including notch" (#355): its
# presets on that output whatever the size (the Mac gives a size that fits
# the one picked), labelled as they are, set through omacvm-displays. Not found (Omarchy changed its
# panel): the panel as Omarchy has it, and the widget still builds.
OPTIONAL_EDITS = [
    ("        return Model.availableScales(scalePresets, display.width, display.height)\n",
     "        return root.macFullPanel !== \"\" && display.name === root.macFullPanel ? scalePresets\n"
     "          : Model.availableScales(scalePresets, display.width, display.height)\n"),
    # The buttons' labels: the preset itself there, not the scale the current
    # size would round it to (at 1.67 on 2940x1915 that read 1x 1.25x 1.67x
    # 2.5x 5x 5x): the Mac gives each preset a size that fits it.
    ("        return Model.cleanScale(scale, display.width, display.height)\n",
     "        return root.macFullPanel !== \"\" && display.name === root.macFullPanel ? normalizeScale(scale)\n"
     "          : Model.cleanScale(scale, display.width, display.height)\n"),
]


def hide_notch(panel: str) -> str:
    """Leave Omanotch's NOTCH output out; the panel as it is if that fails."""
    try:
        loader = importlib.machinery.SourceFileLoader("omanotch_display_panel", str(NOTCH_PATCH))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        return module.patch(panel)
    except (OSError, ValueError, AttributeError) as error:
        print(f"omacvm.monitor: NOTCH stays in the display list ({error})", file=sys.stderr)
        return panel


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out = pathlib.Path(sys.argv[1])
    source = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_SOURCE)
    panel = (source / "Panel.qml").read_text()
    for anchor, replacement in EDITS:
        if panel.count(anchor) != 1:
            print(f"omacvm.monitor: Omarchy's display panel changed (no {anchor.strip()[:60]!r})",
                  file=sys.stderr)
            return 1
        panel = panel.replace(anchor, replacement)
    if COMMONS_ALIAS not in panel:
        if panel.count(COMMONS) != 1:
            print("omacvm.monitor: Omarchy's display panel changed (no single 'import qs.Commons')", file=sys.stderr)
            return 1
        panel = panel.replace(COMMONS, COMMONS + COMMONS_ALIAS)
    if all(panel.count(anchor) == 1 for anchor, _ in OPTIONAL_EDITS):
        for anchor, replacement in OPTIONAL_EDITS:
            panel = panel.replace(anchor, replacement)
    else:
        print("omacvm.monitor: Omarchy's scale buttons changed: in full screen including notch "
              "only the scales its size fits", file=sys.stderr)
    panel = hide_notch(panel)
    out.mkdir(parents=True, exist_ok=True)
    for item in source.iterdir():
        if item.name not in ("Panel.qml", "manifest.json") and item.is_file():
            shutil.copy2(item, out / item.name)
    (out / "Panel.qml").write_text(panel)
    shutil.copy2(HERE / "manifest.json", out / "manifest.json")
    shutil.copy2(HERE / "placement.sh", out / "placement.sh")
    shutil.copy2(HERE / "LICENSE", out / "LICENSE")
    (out / "placement.sh").chmod(0o755)
    digest = hashlib.sha256((source / "Panel.qml").read_bytes()).hexdigest()
    (out / ".source-sha256").write_text(digest + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
