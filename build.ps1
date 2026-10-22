# Gera dist\SimpleBoost.exe (ícone + script embutido). Usa o compilador C# que já vem com o Windows.
#   powershell -ExecutionPolicy Bypass -File build.ps1
$ErrorActionPreference = 'Stop'
$root   = $PSScriptRoot
$assets = Join-Path $root 'assets'
$dist   = Join-Path $root 'dist'
$ico    = Join-Path $assets 'SimpleBoost.ico'
New-Item -ItemType Directory -Path $assets, $dist -Force | Out-Null

# ---------------- Ícone ----------------
# Quadrado laranja arredondado com um "S" branco, em vários tamanhos (PNG dentro do .ico)
function New-IconPng([int]$size) {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object Drawing.Bitmap $size, $size
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([Drawing.Color]::Transparent)

    $r = [math]::Max(2, [int]($size * 0.22))
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
    $path.AddArc($size - $r * 2 - 1, 0, $r * 2, $r * 2, 270, 90)
    $path.AddArc($size - $r * 2 - 1, $size - $r * 2 - 1, $r * 2, $r * 2, 0, 90)
    $path.AddArc(0, $size - $r * 2 - 1, $r * 2, $r * 2, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#F2542D'))), $path)

    $font = New-Object Drawing.Font 'Segoe UI', ([float]($size * 0.62)), ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $rect = New-Object Drawing.RectangleF 0, ([float]($size * 0.03)), $size, $size
    $g.DrawString('S', $font, [Drawing.Brushes]::White, $rect, $fmt)
    $g.Dispose()

    $ms = New-Object IO.MemoryStream
    if ($size -ge 256) {
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    } else {
        # Tamanhos pequenos em DIB 32 bits (formato clássico, lido por qualquer programa)
        $w = New-Object IO.BinaryWriter $ms
        $w.Write([uint32]40); $w.Write([int32]$size); $w.Write([int32]($size * 2))
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]0)
        $w.Write([uint32]($size * $size * 4)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
        for ($y = $size - 1; $y -ge 0; $y--) {
            for ($x = 0; $x -lt $size; $x++) {
                $c = $bmp.GetPixel($x, $y)
                $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A)
            }
        }
        # Máscara AND vazia (a transparência vem do alfa); cada linha alinhada em 4 bytes
        $w.Write((New-Object byte[] ([math]::Ceiling($size / 32) * 4 * $size)))
        $w.Flush()
    }
    $bmp.Dispose()
    return , $ms.ToArray()
}

if (-not (Test-Path $ico)) {
    $sizes = 16, 24, 32, 48, 64, 128, 256
    $pngs = foreach ($s in $sizes) { , (New-IconPng $s) }
    $fs = [IO.File]::Create($ico)
    $w = New-Object IO.BinaryWriter $fs
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]
        $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s })); $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
        $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $w.Write($p) }
    $w.Close()
    Write-Host "Ícone criado: $ico"
}

# ---------------- Executável ----------------
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$exe = Join-Path $dist 'SimpleBoost.exe'
& $csc /nologo /target:winexe /optimize+ "/out:$exe" "/win32icon:$ico" "/win32manifest:$root\launcher\app.manifest" `
    "/resource:$root\SimpleBoost.ps1,SimpleBoost.ps1" "/resource:$ico,SimpleBoost.ico" /r:System.Windows.Forms.dll `
    "$root\launcher\Launcher.cs"
if ($LASTEXITCODE -ne 0) { throw "Falha ao compilar (código $LASTEXITCODE)." }
Write-Host "Pronto: $exe ($([math]::Round((Get-Item $exe).Length / 1KB)) KB)"
