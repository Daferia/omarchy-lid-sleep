import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget for the `lid-sleep` command: shows the current lid-close mode,
// lets you switch it (via pkexec, which raises the shell's password dialog),
// and lists how much battery recent sleeps used.
Panel {
  id: root
  moduleName: "daferia.lid-sleep"
  ipcTarget: "daferia.lid-sleep"

  // The lid-sleep script ships inside this plugin, so it works right after
  // `omarchy plugin add` with no separate install step.
  readonly property string script: decodeURIComponent(String(Qt.resolvedUrl("bin/lid-sleep")).replace(/^(file|qs):\/\//, ""))

  property var status: ({})
  property string busyText: ""
  property string errorText: ""
  property int cursorIndex: -1

  readonly property string mode: status.mode || ""
  readonly property var history: status.history || []

  readonly property var modes: [
    { id: "windows",   icon: "󰤄", label: "Smart",     hint: "Sleep, then hibernate" },
    { id: "suspend",   icon: "󰒲", label: "Sleep",     hint: "Light sleep only" },
    { id: "hibernate", icon: "󰋊", label: "Hibernate", hint: "Hibernate right away" },
    { id: "lock",      icon: "󰌾", label: "Lock",      hint: "Lock, stay awake" },
    { id: "ignore",    icon: "󰅙", label: "Nothing",   hint: "Ignore the lid" }
  ]
  readonly property var delays: ["15min", "30min", "1h", "2h", "3h"]

  function modeInfo(id) {
    for (var i = 0; i < modes.length; i++) if (modes[i].id === id) return modes[i]
    return { id: "default", icon: "󰒲", label: "Sleep", hint: "System default (light sleep)" }
  }

  // "60min" and "1h" are the same delay; compare in minutes.
  function delayMinutes(d) {
    var m = String(d || "").match(/^(?:(\d+)h)?\s*(?:(\d+)min)?$/)
    if (!m) return -1
    return (parseInt(m[1] || "0") * 60) + parseInt(m[2] || "0")
  }

  function formatDuration(min) {
    if (min < 60) return min + "m"
    var h = Math.floor(min / 60), m = min % 60
    return m ? h + "h " + m + "m" : h + "h"
  }

  function ratePerHour(e) {
    return e.minutes > 0 ? (e.from - e.to) / (e.minutes / 60) : 0
  }

  // Average drain per sleep type, weighted by time spent in it.
  function averageRate(type) {
    var used = 0, mins = 0
    for (var i = 0; i < history.length; i++) {
      if (history[i].type !== type) continue
      used += history[i].from - history[i].to
      mins += history[i].minutes
    }
    return mins >= 30 ? (used / (mins / 60)).toFixed(1) + "%/h" : "—"
  }

  readonly property string statusLine: {
    if (busyText) return busyText
    if (!status.mode) return "Loading…"
    if (mode === "windows") return "Sleep → hibernate after " + status.delay
    return modeInfo(mode).hint
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function run(args, label) {
    if (actionProc.running) return
    errorText = ""
    busyText = label
    actionProc.command = ["pkexec", root.script].concat(args)
    actionProc.running = true
  }

  function setMode(id) {
    if (id === mode) return
    if (id === "windows") run(["set", "windows", status.delay || "60min"], "Switching to smart sleep…")
    else run(["set", id], "Switching to " + modeInfo(id).label.toLowerCase() + "…")
  }

  function setDelay(d) {
    if (delayMinutes(d) === delayMinutes(status.delay)) return
    run(["delay", d], "Setting delay to " + d + "…")
  }

  onOpenedChanged: if (opened) { refresh(); cursorIndex = -1 }
  Component.onCompleted: refresh()

  Process {
    id: statusProc
    command: [root.script, "json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.status = JSON.parse(text) } catch (e) { root.errorText = "Could not run " + root.script }
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(code) {
      root.busyText = ""
      // pkexec: 126 = password dialog dismissed, 127 = not authorized
      if (code === 126 || code === 127) root.errorText = "Cancelled"
      else if (code !== 0) root.errorText = String(actionErr.text || "Failed").trim().split("\n").pop()
      root.refresh()
    }
  }

  // Keep the bar icon in sync if the mode is changed from a terminal.
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.modeInfo(root.mode).icon
    tooltipText: ""
    onPressed: function(b) { root.toggle() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        var n = root.modes.length
        if (root.cursorIndex < 0) { root.cursorIndex = 0; return }
        var step = dx !== 0 ? dx : dy * 3
        root.cursorIndex = Math.max(0, Math.min(n - 1, root.cursorIndex + step))
      }
      onActivateRequested: if (root.cursorIndex >= 0) root.setMode(root.modes[root.cursorIndex].id)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            text: root.modeInfo(root.mode).icon
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Lid close"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusLine.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        Text {
          visible: root.errorText !== "" || (!!root.status.mode && root.status.hibernationReady === false)
          text: root.errorText !== "" ? root.errorText : "Hibernation isn't set up: run omarchy hibernation setup"
          color: Color.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          width: parent.width
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Mode picker ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "WHEN THE LID CLOSES"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Grid {
            id: modeGrid
            width: parent.width
            columns: 3
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

            Repeater {
              model: root.modes
              Button {
                required property var modelData
                required property int index
                width: modeGrid.cellWidth
                iconText: modelData.icon
                iconSize: Style.font.title
                text: modelData.label
                tooltipText: modelData.hint
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.mode === modelData.id || (root.mode === "default" && modelData.id === "suspend")
                hasCursor: root.cursorIndex === index
                onClicked: root.setMode(modelData.id)
                onHovered: function(h) { if (h) root.cursorIndex = index }
              }
            }
          }
        }

        // ---------- Hibernate delay (smart mode only) ----------
        Column {
          visible: root.mode === "windows"
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "HIBERNATE AFTER (ON BATTERY)"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: delayRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * (root.delays.length - 1)) / root.delays.length

            Repeater {
              model: root.delays
              Button {
                required property var modelData
                width: delayRow.cellWidth
                text: modelData.replace("min", "m")
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: root.delayMinutes(modelData) === root.delayMinutes(root.status.delay)
                onClicked: root.setDelay(modelData)
              }
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- History ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "BATTERY USED WHILE ASLEEP"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(20)
            visible: root.history.length > 0
            Stat { label: "Light sleep"; value: root.averageRate("suspend") }
            Stat { label: "Hibernate"; value: root.averageRate("hibernate") }
          }

          Text {
            visible: root.history.length === 0
            text: root.status.recording ? "No sleeps recorded yet." : "Not recording: pick a mode above to start."
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            // Newest first, last 6 entries.
            model: root.history.slice(-6).reverse()
            Row {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Cell { width: parent.width * 0.32; text: Qt.formatDateTime(new Date(modelData.start * 1000), "ddd HH:mm"); dim: true }
              Cell { width: parent.width * 0.24; text: modelData.type === "hibernate" ? "Hibernate" : "Sleep" }
              Cell { width: parent.width * 0.16; text: root.formatDuration(modelData.minutes); dim: true }
              Cell {
                width: parent.width * 0.28 - parent.spacing * 3
                horizontalAlignment: Text.AlignRight
                text: (modelData.from - modelData.to) + "% · " + root.ratePerHour(modelData).toFixed(1) + "/h"
              }
            }
          }
        }
      }
    }
  }

  component Stat: Column {
    property string label: ""
    property string value: ""
    spacing: Style.space(2)
    Text {
      text: parent.value
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }
    Text {
      text: parent.label
      color: root.bar.foreground
      opacity: 0.6
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component Cell: Text {
    property bool dim: false
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: dim ? 0.6 : 1
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }
}
