Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.IO.MemoryMappedFiles;

[StructLayout(LayoutKind.Sequential, Pack=1)]
public struct HWiNFO_SHARED_MEM {
    public uint dwSignature;
    public uint dwVersion;
    public uint dwRevision;
    public long poll_time;
    public uint dwOffsetOfSensorSection;
    public uint dwSizeOfSensorElement;
    public uint dwNumSensorElements;
    public uint dwOffsetOfReadingSection;
    public uint dwSizeOfReadingElement;
    public uint dwNumReadingElements;
}

[StructLayout(LayoutKind.Sequential, Pack=1, CharSet=CharSet.Unicode)]
public struct HWiNFO_SENSOR {
    public uint dwSensorID;
    public uint dwSensorInst;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)]
    public string szSensorNameOrig;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)]
    public string szSensorNameUser;
}

[StructLayout(LayoutKind.Sequential, Pack=1, CharSet=CharSet.Unicode)]
public struct HWiNFO_READING {
    public int tReading;
    public uint dwSensorIndex;
    public uint dwReadingID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)]
    public string szLabelOrig;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)]
    public string szLabelUser;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=16)]
    public string szUnit;
    public double Value;
    public double ValueMin;
    public double ValueMax;
    public double ValueAvg;
}
"@

try {
    $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting("Global\HWiNFO_SENSORS_SM2")
    $accessor = $mmf.CreateViewAccessor()

    $hdrSize = [System.Runtime.InteropServices.Marshal]::SizeOf([HWiNFO_SHARED_MEM])
    $hdr = New-Object HWiNFO_SHARED_MEM
    $accessor.Read(0, [ref]$hdr)

    Write-Host "=== HWiNFO64 Power Readings ==="
    Write-Host "Sensors: $($hdr.dwNumSensorElements)  Readings: $($hdr.dwNumReadingElements)"
    Write-Host ""

    $readingSize = [System.Runtime.InteropServices.Marshal]::SizeOf([HWiNFO_READING])
    $powerReadings = @()

    for ($i = 0; $i -lt $hdr.dwNumReadingElements; $i++) {
        $offset = $hdr.dwOffsetOfReadingSection + ($i * $hdr.dwSizeOfReadingElement)
        $r = New-Object HWiNFO_READING
        $accessor.Read($offset, [ref]$r)
        # tReading == 5 is Power (Watt)
        if ($r.tReading -eq 5) {
            $powerReadings += $r
            Write-Host ("{0,-45} {1,8:F2} {2}" -f $r.szLabelOrig, $r.Value, $r.szUnit)
        }
    }

    if ($powerReadings.Count -eq 0) {
        Write-Host "No power readings found. Dumping all reading types present:"
        $types = @{}
        for ($i = 0; $i -lt $hdr.dwNumReadingElements; $i++) {
            $offset = $hdr.dwOffsetOfReadingSection + ($i * $hdr.dwSizeOfReadingElement)
            $r = New-Object HWiNFO_READING
            $accessor.Read($offset, [ref]$r)
            $types[$r.tReading] = $true
        }
        Write-Host "Types found: $($types.Keys -join ', ')"
    }

    $accessor.Dispose()
    $mmf.Dispose()
} catch {
    Write-Host "ERROR: $_"
    Write-Host "Make sure HWiNFO64 is running with shared memory enabled (Settings > Shared Memory Support)"
}
