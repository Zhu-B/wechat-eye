param([string]$Image = "")
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
# WinRT StorageFile 只认反斜杠规范路径: 正斜杠能过 Test-Path, 却让
# GetFileFromPathAsync 抛 "One or more errors occurred"(2026-10-10 实测
# agent 传正斜杠路径七连炸) —— 进门先规范化, 斜杠/相对路径一律救回来.
$Image = [System.IO.Path]::GetFullPath($Image)
if (-not (Test-Path $Image)) { Write-Output ("ERROR: image not found: " + $Image); exit 1 }
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($WinRtTask, $ResultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
  $netTask = $asTask.Invoke($null, @($WinRtTask))
  $netTask.Wait(-1) | Out-Null
  $netTask.Result
}

$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (-not $engine) { Write-Output 'ERROR: no OCR engine for user languages'; exit 1 }

# NB: BitmapDecoder::CreateAsync($file) fails overload resolution in PS;
# must go through a stream: OpenAsync(Read) -> CreateAsync($stream)
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Image)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$soft = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$res = Await ($engine.RecognizeAsync($soft)) ([Windows.Media.Ocr.OcrResult])

Write-Output ("LANG: " + $engine.RecognizerLanguage.LanguageTag)
Write-Output ("LINES: " + $res.Lines.Count)
$i = 0
foreach ($l in $res.Lines) { $i++; Write-Output ("[" + $i + "] " + $l.Text) }
