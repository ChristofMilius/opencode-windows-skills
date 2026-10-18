# patch-opencode-zoom.ps1
#
# Re-applies the local zoom-persistence patch to the OpenCode desktop app
# (app.asar). The app's wireZoom() unconditionally calls
# setZoomFactor(1) on window creation, which discards the zoom level
# Chromium persists (Preferences -> partition.per_host_zoom_levels).
# Upstream bug: https://github.com/anomalyco/opencode/issues/50168
# Upstream fix (not yet released): PR #50169
#
# The patch replaces the reset call with `void 0` plus padding spaces so
# the byte length of the JS file is unchanged - the asar archive layout
# stays valid and no repacking is needed. Everything else in wireZoom
# (pinch-zoom wiring, mouse-wheel zoom handler, title bar sync) keeps
# working. Zoom set with Ctrl+= is persisted by Chromium and restored
# on the next launch.
#
# Usage:
#   pwsh -NoProfile -File patch-opencode-zoom.ps1        apply (idempotent)
#
# Run it again after every desktop app UPDATE (the updater replaces
# app.asar, which discards the patch). Exit code 0 = patched or already
# patched; exit code 1 = original pattern not found (app updated with
# different code, or upstream shipped the real fix - check manually).

$asar = Join-Path $env:LOCALAPPDATA 'Programs\@opencode-aidesktop\resources\app.asar'

if (-not (Test-Path -LiteralPath $asar)) {
    Write-Error "app.asar not found at $asar"
    exit 1
}

# Byte-length-preserving replacements (both must be exactly 62 bytes):
$orig    = 'Pd.set(e,Gd()),e.webContents.setZoomFactor(1),e.webContents.on'
$patched = 'Pd.set(e,Gd()),void 0,' + (' ' * 24) + 'e.webContents.on'

if ($orig.Length -ne $patched.Length) {
    Write-Error 'internal error: replacement is not byte-length-preserving'
    exit 1
}

# Latin-1 gives a 1:1 byte<->char mapping, so string ops are byte-safe
# on the binary archive.
$enc = [System.Text.Encoding]::GetEncoding(28591)
$text = [System.IO.File]::ReadAllText($asar, $enc)

$cntOrig    = ([regex]::Matches($text, [regex]::Escape($orig))).Count
$cntPatched = ([regex]::Matches($text, [regex]::Escape($patched))).Count

if ($cntPatched -ge 1 -and $cntOrig -eq 0) {
    Write-Output "[zoom-patch] already patched - nothing to do."
    exit 0
}

if ($cntOrig -ne 1) {
    $msg = ("[zoom-patch] expected exactly 1 unpatched match, found {0} (patched: {1})." +
        " The app may have been updated with different code, or upstream shipped the fix" +
        " (PR #50169) - if so, this patch is obsolete.") -f $cntOrig, $cntPatched
    Write-Error $msg
    exit 1
}

$bak = "$asar.zoompatch.bak"
Copy-Item -LiteralPath $asar -Destination $bak -Force
Write-Output "[zoom-patch] backup written: $bak"

$newText = $text.Replace($orig, $patched)
[System.IO.File]::WriteAllText($asar, $newText, $enc)

# Verify on disk.
$verify = [System.IO.File]::ReadAllText($asar, $enc)
if ($verify.Contains($patched) -and -not $verify.Contains($orig)) {
    Write-Output '[zoom-patch] applied and verified. Restart the OpenCode desktop app.'
    exit 0
}

# Restore on failed verification.
Copy-Item -LiteralPath $bak -Destination $asar -Force
Write-Error '[zoom-patch] verification failed - asar restored from backup.'
exit 1
