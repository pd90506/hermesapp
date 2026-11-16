# Builds a small ISO holding autounattend.xml, so Windows Setup in the test VM finds it.
# Uses the IMAPI2 file-system COM objects that ship with Windows: no ADK, no admin rights.
#
#   New-AnswerIso.ps1 -Source <folder with autounattend.xml> -Iso <output .iso>
param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Iso
)
$ErrorActionPreference = 'Stop'

$image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$image.FileSystemsToCreate = 3  # ISO 9660 + Joliet
$image.VolumeName = 'UNATTEND'
$image.Root.AddTree((Resolve-Path $Source).Path, $false)
$stream = $image.CreateResultImage().ImageStream

# IStream -> file. PowerShell cannot call IStream::Read directly, so a small C# helper does.
if (-not ('IsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class IsoWriter {
    public static void Write(object stream, string path) {
        var source = (IStream)stream;
        var buffer = new byte[65536];
        var read = Marshal.AllocHGlobal(sizeof(int));
        try {
            using (var file = File.Create(path)) {
                while (true) {
                    source.Read(buffer, buffer.Length, read);
                    int n = Marshal.ReadInt32(read);
                    if (n <= 0) break;
                    file.Write(buffer, 0, n);
                }
            }
        } finally { Marshal.FreeHGlobal(read); }
    }
}
'@
}
[IsoWriter]::Write($stream, $Iso)
Get-Item $Iso
