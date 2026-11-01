param([Parameter(Mandatory=$true)][string]$Source, [Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$image = [Drawing.Image]::FromFile($Source)
# The native Win32 STATIC bitmap control cannot load PNG.
# Generate its exact 38 logical pixel footprint at each supported system DPI.
try {
 foreach ($percent in @(100,125,150,175,200,225,250,300,350,400)) {
  $size = [int](38 * $percent / 100)
  $bitmap = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
   $graphics.Clear([Drawing.ColorTranslator]::FromHtml('#f4f7fb'))
   $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
   $graphics.DrawImage($image, 0, 0, $size, $size)
   $file = if ($percent -eq 100) { $Destination } else { $Destination.Replace('.bmp', "-$percent.bmp") }
   $bitmap.Save($file, [Drawing.Imaging.ImageFormat]::Bmp)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
 }
} finally { $image.Dispose() }
