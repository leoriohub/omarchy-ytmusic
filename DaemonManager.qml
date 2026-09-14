import QtQuick
import Quickshell
import Quickshell.Io

import "Api.js" as Api

Item {
  id: root

  visible: false
  width: 0
  height: 0

  property string pluginDir: ""
  property int bitrateKbps: 320
  property int idleMinutes: 15
  property string unitName: "omarchy-ytmusic.service"

  property bool binaryAvailable: false
  property bool binaryChecked: false
  property bool unitAvailable: false
  property bool unitChecked: false
  property bool serviceActive: false
  property bool automaticSetupAttempted: false
  readonly property bool requirementsChecked: binaryChecked && unitChecked
  readonly property bool playbackReady: binaryAvailable && unitAvailable
  readonly property bool setupRequired: requirementsChecked && !playbackReady
  readonly property bool running: serviceActive
  property bool busy: false
  property bool setupBusy: false
  property string lastError: ""

  signal started()
  signal stopped()
  signal setupSucceeded()
  signal setupFailed(string reason)

  function safeError(value) {
    return Api.redact(String(value || ""))
  }

  function checkRequirements() {
    if (!pluginDir) return
    if (!binaryCheck.running) {
      binaryCheck.command = ["/usr/bin/bash",
        pluginDir + "/scripts/playback-runtime.sh", "check"]
      binaryCheck.running = true
    }
    if (!unitCheck.running) {
      unitCheck.command = ["/usr/bin/bash",
        pluginDir + "/scripts/playback-runtime.sh", "unit"]
      unitCheck.running = true
    }
  }

  function installBundledBackendIfNeeded() {
    if (automaticSetupAttempted || setupBusy || !pluginDir
        || !requirementsChecked) return
    if (playbackReady) return
    automaticSetupAttempted = true
    setupPlayback()
  }

  // How long a setup run may take before it is treated as hung. Installing the
  // venv and its dependencies is a pip round trip, so this is generous; the
  // point is only to guarantee the flag can never latch forever.
  readonly property int setupTimeoutMs: 300000

  function setupPlayback() {
    if (setupBusy || !pluginDir) return
    lastError = ""
    setupBusy = true
    setupCommand.command = [pluginDir + "/scripts/setup.sh"]
    setupCommand.running = true
    setupTimeout.restart()
  }

  // `setupBusy` used to be cleared only in setupCommand.onExited. If that
  // handler never ran — the shell restarted mid-setup, the process was killed,
  // or Quickshell dropped the child — the flag latched true and every later
  // call returned early on the guard above. The UI then showed "Working…"
  // forever with no error and no way to retry short of restarting the shell.
  function cancelSetup(reason) {
    if (!setupBusy) return
    if (setupCommand.running) setupCommand.running = false
    setupBusy = false
    setupTimeout.stop()
    lastError = root.safeError(reason || "Playback setup did not finish")
    root.setupFailed(root.lastError)
  }

  function refreshStatus() {
    if (!pluginDir || statusCheck.running) return
    statusCheck.command = ["/usr/bin/bash",
      pluginDir + "/scripts/playback-runtime.sh", "status"]
    statusCheck.running = true
  }

  function start() {
    if (busy || !pluginDir) return
    if (!binaryAvailable || !unitAvailable) {
      lastError = "Playback support needs to be set up"
      return
    }
    lastError = ""
    busy = true
    startCommand.command = ["/usr/bin/bash",
      pluginDir + "/scripts/playback-runtime.sh", "start", pluginDir]
    startCommand.running = true
  }

  function stop() {
    lastError = ""
    busy = true
    stopCommand.command = ["/usr/bin/bash",
      pluginDir + "/scripts/playback-runtime.sh", "stop"]
    stopCommand.running = true
  }

  Process {
    id: binaryCheck
    running: false
    onExited: function(code) {
      root.binaryAvailable = Number(code) === 0
      root.binaryChecked = true
    }
  }

  Process {
    id: unitCheck
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.unitAvailable = text.trim() !== ""
        root.unitChecked = true
      }
    }
    onExited: function(code) {
      if (Number(code) !== 0) {
        root.unitAvailable = false
        root.unitChecked = true
      }
    }
  }

  Process {
    id: statusCheck
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.serviceActive = text.trim() === "active"
    }
    onExited: function(code) {
      if (Number(code) !== 0) root.serviceActive = false
    }
  }

  Process {
    id: setupCommand
    running: false
    stderr: StdioCollector { }
    onExited: function(code) {
      root.setupBusy = false
      root.setupTimeout.stop()
      if (Number(code) === 0) {
        root.lastError = ""
        root.checkRequirements()
        root.setupSucceeded()
      } else {
        root.lastError = root.safeError(setupCommand.stderr.text
          || "Could not install YouTube Music playback")
        root.setupFailed(root.lastError)
      }
    }
  }

  Process {
    id: startCommand
    running: false
    stderr: StdioCollector { }
    onExited: function(code) {
      root.busy = false
      if (Number(code) === 0) {
        root.serviceActive = true
        root.started()
      } else {
        root.lastError = root.safeError(startCommand.stderr.text
          || "Could not start YouTube Music playback")
      }
    }
  }

  Process {
    id: stopCommand
    running: false
    onExited: function() {
      root.busy = false
      root.serviceActive = false
      root.stopped()
    }
  }

  Timer {
    interval: 4000
    running: root.playbackReady
    repeat: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: setupTimeout
    interval: root.setupTimeoutMs
    repeat: false
    onTriggered: root.cancelSetup("Playback setup timed out after "
      + Math.round(root.setupTimeoutMs / 60000) + " minutes")
  }

  onPluginDirChanged: if (pluginDir) checkRequirements()
  onRequirementsCheckedChanged: if (requirementsChecked)
    installBundledBackendIfNeeded()
}
