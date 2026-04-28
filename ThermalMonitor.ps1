# PowerShell script to monitor CPU/GPU usage, temperatures, and log potential thermal throttling causes
# Requirements: Run as Administrator for full access to system data
# Optional: Install Open Hardware Monitor or HWMonitor for temperature data

# Log file setup
$logFile = "C:\Temp\ThermalMonitor_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$logDir = "C:\Temp"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

# Initialize tracking variables for heat analysis
$script:processHistory = @{}
$script:temperatureHistory = @()
$script:systemTelemetryHistory = @()
$script:throttleEvents = @()
$script:gpuWarningShown = $false
$script:telemetryWarningsShown = @{}

# Function to write to log file
function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
}

function Write-LogOnce {
    param(
        [string]$Key,
        [string]$Message
    )

    if (-not $script:telemetryWarningsShown.ContainsKey($Key)) {
        Write-Log $Message
        $script:telemetryWarningsShown[$Key] = $true
    }
}

# Function to show progress animation
function Show-Progress {
    param($CurrentIteration, $TotalIterations, $Activity)
    $percent = [math]::Round(($CurrentIteration / $TotalIterations) * 100, 1)
    $progressBar = "█" * [math]::Floor($percent / 5) + "░" * (20 - [math]::Floor($percent / 5))
    
    Write-Host "`r[$progressBar] $percent% - $Activity" -NoNewline -ForegroundColor Cyan
}

# Function to show spinning animation
function Show-SpinningCursor {
    param($Index)
    $spinChars = @('|', '/', '-', '\')
    $char = $spinChars[$Index % 4]
    Write-Host "`r$char Collecting data..." -NoNewline -ForegroundColor Yellow
}

# Function to get CPU usage by process with enhanced metrics
function Get-TopCpuProcesses {
    try {
        # Get performance counter data
        $cpuCounters = Get-Counter "\Process(*)\% Processor Time" -ErrorAction Stop
        $cpuCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
        
        # Get all running processes for mapping
        $runningProcesses = Get-Process
        $processMap = @{}
        
        # Build process map by name (handle duplicates)
        foreach ($proc in $runningProcesses) {
            $key = $proc.Name
            if (-not $processMap.ContainsKey($key)) {
                $processMap[$key] = @()
            }
            $processMap[$key] += $proc
        }
        
        # Process counter samples and normalize instance names
        $processedData = @{}
        foreach ($sample in $cpuCounters.CounterSamples) {
            if ($sample.InstanceName -eq "_total" -or $sample.InstanceName -eq "idle") {
                continue
            }
            
            # Handle instance names with # (e.g., chrome#1, chrome#2)
            $baseName = $sample.InstanceName -replace '#\d+$', ''
            $normalizedCPU = [math]::Round($sample.CookedValue / $cpuCount, 2)
            
            if ($normalizedCPU -gt 0) {
                if (-not $processedData.ContainsKey($baseName)) {
                    $processedData[$baseName] = @{
                        Name = $baseName
                        CPUPercent = 0
                        WorkingSetMB = 0
                        ThreadCount = 0
                        HandleCount = 0
                        InstanceCount = 0
                    }
                }
                
                # Aggregate CPU usage for multiple instances
                $processedData[$baseName].CPUPercent += $normalizedCPU
                $processedData[$baseName].InstanceCount++
            }
        }
        
        # Add process details from Get-Process
        foreach ($key in $processedData.Keys) {
            if ($processMap.ContainsKey($key)) {
                $procs = $processMap[$key]
                # Sum up metrics for all instances of the same process
                $totalMemory = ($procs | Measure-Object WorkingSet64 -Sum).Sum
                $totalThreads = ($procs | Measure-Object { $_.Threads.Count } -Sum).Sum
                $totalHandles = ($procs | Measure-Object HandleCount -Sum).Sum
                
                $processedData[$key].WorkingSetMB = [math]::Round($totalMemory / 1MB, 2)
                $processedData[$key].ThreadCount = $totalThreads
                $processedData[$key].HandleCount = $totalHandles
            }
        }
        
        # Convert to array and sort by CPU usage
        $processes = $processedData.Values | 
            Sort-Object CPUPercent -Descending |
            Select-Object -First 10
            
        return $processes
        
    } catch {
        Write-Log "Error getting CPU performance counters: $_"
        # Fallback method
        $processes = Get-Process | Where-Object { $_.CPU -gt 0 } | 
            Sort-Object CPU -Descending | 
            Select-Object -First 10 |
            Select-Object Name, ID, 
                @{Name="CPUTime";Expression={[math]::Round($_.CPU,2)}}, 
                @{Name="WorkingSetMB";Expression={[math]::Round($_.WorkingSet64/1MB,2)}},
                @{Name="ThreadCount";Expression={$_.Threads.Count}}
        return $processes
    }
}

# Function to get high process I/O rates as an extra heat contributor signal
function Get-TopIoProcesses {
    try {
        $ioCounters = Get-Counter "\Process(*)\IO Data Bytes/sec" -ErrorAction Stop
        $processedData = @{}

        foreach ($sample in $ioCounters.CounterSamples) {
            if ($sample.InstanceName -eq "_total" -or $sample.InstanceName -eq "idle") {
                continue
            }

            $baseName = $sample.InstanceName -replace '#\d+$', ''
            $ioMBps = [math]::Round($sample.CookedValue / 1MB, 2)

            if ($ioMBps -gt 0) {
                if (-not $processedData.ContainsKey($baseName)) {
                    $processedData[$baseName] = @{
                        Name = $baseName
                        IOMBps = 0
                        InstanceCount = 0
                    }
                }

                $processedData[$baseName].IOMBps += $ioMBps
                $processedData[$baseName].InstanceCount++
            }
        }

        return $processedData.Values |
            Sort-Object IOMBps -Descending |
            Select-Object -First 10
    } catch {
        Write-LogOnce -Key "ProcessIoCounters" -Message "Process I/O counters unavailable: $_"
        return $null
    }
}

# Function to get GPU usage with process mapping
function Get-GpuUsage {
    try {
        # Check Windows version and GPU driver support
        $osVersion = [System.Environment]::OSVersion.Version
        if ($osVersion.Major -lt 10 -or ($osVersion.Major -eq 10 -and $osVersion.Build -lt 17763)) {
            if (-not $script:gpuWarningShown) {
                Write-Log "GPU monitoring requires Windows 10 build 17763 or higher"
                $script:gpuWarningShown = $true
            }
            return $null
        }
        
        # Try to get GPU usage per process
        $gpuCounters = Get-Counter "\GPU Engine(*)\Utilization Percentage" -ErrorAction Stop

        $processNameById = @{}
        Get-Process | ForEach-Object {
            $processNameById[[int]$_.Id] = $_.Name
        }
        
        $gpuData = $gpuCounters.CounterSamples | 
            Where-Object { $_.CookedValue -gt 0 } |
            ForEach-Object {
                # GPU Engine counter instances include the process ID on supported systems.
                $instanceName = $_.InstanceName
                $processId = $null
                if ($instanceName -match 'pid_(\d+)') {
                    $processId = [int]$matches[1]
                }

                $processName = if ($null -ne $processId -and $processNameById.ContainsKey($processId)) {
                    $processNameById[$processId]
                } elseif ($null -ne $processId) {
                    "PID $processId"
                } elseif ($instanceName -match '^([^_]+)_') {
                    $matches[1]
                } else {
                    $instanceName
                }
                
                [PSCustomObject]@{
                    Name = $processName
                    ProcessId = $processId
                    GPUPercent = [math]::Round($_.CookedValue, 2)
                    EngineType = if ($instanceName -match 'engtype_(\w+)') { $matches[1] } else { "Unknown" }
                }
            } |
            Group-Object Name |
            ForEach-Object {
                $processIds = ($_.Group | Where-Object { $null -ne $_.ProcessId } | Select-Object -ExpandProperty ProcessId -Unique) -join ","
                $engineTypes = ($_.Group | Select-Object -ExpandProperty EngineType -Unique) -join ","

                [PSCustomObject]@{
                    Name = $_.Name
                    GPUPercent = [math]::Round(($_.Group | Measure-Object GPUPercent -Sum).Sum, 2)
                    ProcessIds = $processIds
                    EngineTypes = $engineTypes
                }
            } |
            Sort-Object GPUPercent -Descending |
            Select-Object -First 10
        
        return $gpuData
        
    } catch {
        if (-not $script:gpuWarningShown) {
            Write-Log "GPU counters unavailable: $_"
            $script:gpuWarningShown = $true
        }
        return $null
    }
}

# Helper function to convert Celsius to Fahrenheit
function ConvertTo-Fahrenheit {
    param($Celsius)
    return [math]::Round(($Celsius * 9/5) + 32, 1)
}

# Enhanced temperature function with averaging
function Get-CpuTemperature {
    $temperature = $null
    $hardwareMonitorSources = @(
        @{ Namespace = "root\LibreHardwareMonitor"; Source = "LibreHardwareMonitor" },
        @{ Namespace = "root\OpenHardwareMonitor"; Source = "OpenHardwareMonitor" }
    )
    
    foreach ($hardwareMonitorSource in $hardwareMonitorSources) {
        try {
            $sensors = Get-CimInstance -Namespace $hardwareMonitorSource.Namespace -Class Sensor -ErrorAction Stop
            $cpuTemps = $sensors | Where-Object {
                $sensorName = [string]$_.Name
                $identifier = [string]$_.Identifier
                $parent = [string]$_.Parent

                $_.SensorType -eq "Temperature" -and
                $sensorName -notmatch "GPU|Graphics" -and
                (
                    $sensorName -match "CPU|Package|Tctl|Tdie" -or
                    $identifier -match "cpu|processor" -or
                    $parent -match "cpu|processor"
                ) -and
                $null -ne $_.Value -and
                [double]$_.Value -gt 0 -and
                [double]$_.Value -lt 150
            }

            if ($cpuTemps) {
                $avgTemp = ($cpuTemps | Measure-Object -Property Value -Average).Average
                $maxTemp = ($cpuTemps | Measure-Object -Property Value -Maximum).Maximum
                $cpuPowerSensors = $sensors | Where-Object {
                    $sensorName = [string]$_.Name
                    $identifier = [string]$_.Identifier
                    $parent = [string]$_.Parent

                    $_.SensorType -eq "Power" -and
                    $sensorName -notmatch "GPU|Graphics" -and
                    (
                        $sensorName -match "CPU|Package" -or
                        $identifier -match "cpu|processor" -or
                        $parent -match "cpu|processor"
                    ) -and
                    $null -ne $_.Value -and
                    [double]$_.Value -gt 0
                }
                $fanSensors = $sensors | Where-Object {
                    $_.SensorType -eq "Fan" -and
                    $null -ne $_.Value -and
                    [double]$_.Value -gt 0
                }

                $avgCpuPower = if ($cpuPowerSensors) {
                    [math]::Round(($cpuPowerSensors | Measure-Object -Property Value -Average).Average, 1)
                } else { $null }
                $maxCpuPower = if ($cpuPowerSensors) {
                    [math]::Round(($cpuPowerSensors | Measure-Object -Property Value -Maximum).Maximum, 1)
                } else { $null }
                $avgFanRpm = if ($fanSensors) {
                    [math]::Round(($fanSensors | Measure-Object -Property Value -Average).Average, 0)
                } else { $null }

                $temperature = @{
                    Average = [math]::Round($avgTemp, 1)
                    AverageF = ConvertTo-Fahrenheit $avgTemp
                    Max = [math]::Round($maxTemp, 1)
                    MaxF = ConvertTo-Fahrenheit $maxTemp
                    Source = $hardwareMonitorSource.Source
                    PowerWatts = $avgCpuPower
                    MaxPowerWatts = $maxCpuPower
                    FanRPM = $avgFanRpm
                    Details = $cpuTemps | Select-Object Name, Value, @{Name="ValueF";Expression={ConvertTo-Fahrenheit $_.Value}}
                }

                break
            }
        } catch [Microsoft.Management.Infrastructure.CimException] {
            if ($_.Exception.Message -like "*Invalid namespace*" -or $_.Exception.Message -like "*Invalid class*") {
                Write-LogOnce -Key $hardwareMonitorSource.Source -Message "$($hardwareMonitorSource.Source) sensor namespace is not available"
            } else {
                Write-LogOnce -Key $hardwareMonitorSource.Source -Message "Error accessing $($hardwareMonitorSource.Source): $_"
            }
        } catch {
            Write-LogOnce -Key $hardwareMonitorSource.Source -Message "Unexpected error with $($hardwareMonitorSource.Source): $_"
        }
    }
    
    # Fall back to Windows built-in thermal zones if no temperature data yet
    if (-not $temperature) {
        try {
            $thermalZones = Get-CimInstance -Namespace "root\wmi" -Class MSAcpi_ThermalZoneTemperature -ErrorAction Stop
            if ($thermalZones) {
                $temps = $thermalZones | ForEach-Object {
                    ($_.CurrentTemperature / 10) - 273.15
                } | Where-Object { $_ -gt 0 -and $_ -lt 150 } # Filter out invalid readings
                
                if ($temps) {
                    $avgTemp = ($temps | Measure-Object -Average).Average
                    $maxTemp = ($temps | Measure-Object -Maximum).Maximum
                    $temperature = @{
                        Average = [math]::Round($avgTemp, 1)
                        AverageF = ConvertTo-Fahrenheit $avgTemp
                        Max = [math]::Round($maxTemp, 1)
                        MaxF = ConvertTo-Fahrenheit $maxTemp
                        Source = "Windows Thermal Zones"
                        PowerWatts = $null
                        MaxPowerWatts = $null
                        FanRPM = $null
                        Details = "ACPI thermal zone data"
                    }
                }
            }
        } catch {
            # No temperature sensors accessible
        }
    }
    
    return $temperature
}

# Function to get total CPU load for throttling context
function Get-TotalCpuUsage {
    try {
        $counter = Get-Counter "\Processor(_Total)\% Processor Time" -ErrorAction Stop
        return [math]::Round($counter.CounterSamples[0].CookedValue, 2)
    } catch {
        try {
            $cpuLoad = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average
            if ($null -ne $cpuLoad) {
                return [math]::Round($cpuLoad, 2)
            }
        } catch {
            Write-Log "Unable to get total CPU usage: $_"
        }
    }

    return $null
}

function Get-CounterMetric {
    param(
        [string[]]$CounterPaths,
        [ValidateSet("Average", "Maximum", "Sum")]
        [string]$Aggregate = "Average",
        [scriptblock]$Filter
    )

    foreach ($counterPath in $CounterPaths) {
        try {
            $counter = Get-Counter $counterPath -ErrorAction Stop
            $samples = @($counter.CounterSamples)

            if ($Filter) {
                $samples = @($samples | Where-Object $Filter)
            }

            if ($samples.Count -eq 0) {
                continue
            }

            $measurement = switch ($Aggregate) {
                "Maximum" { $samples | Measure-Object -Property CookedValue -Maximum }
                "Sum" { $samples | Measure-Object -Property CookedValue -Sum }
                default { $samples | Measure-Object -Property CookedValue -Average }
            }

            $value = switch ($Aggregate) {
                "Maximum" { $measurement.Maximum }
                "Sum" { $measurement.Sum }
                default { $measurement.Average }
            }

            return [PSCustomObject]@{
                Value = [math]::Round($value, 2)
                Counter = $counterPath
            }
        } catch {
            Write-LogOnce -Key $counterPath -Message "Counter unavailable ($counterPath): $_"
        }
    }

    return $null
}

function Get-CpuPerformanceTelemetry {
    $performance = Get-CounterMetric -CounterPaths @("\Processor Information(_Total)\% Processor Performance")
    $frequency = Get-CounterMetric -CounterPaths @("\Processor Information(_Total)\% of Maximum Frequency")

    return [PSCustomObject]@{
        PerformancePercent = if ($performance) { $performance.Value } else { $null }
        PerformanceCounter = if ($performance) { $performance.Counter } else { $null }
        FrequencyPercent = if ($frequency) { $frequency.Value } else { $null }
        FrequencyCounter = if ($frequency) { $frequency.Counter } else { $null }
    }
}

function Get-KernelActivity {
    $dpcTime = Get-CounterMetric -CounterPaths @(
        "\Processor Information(_Total)\% DPC Time",
        "\Processor(_Total)\% DPC Time"
    )
    $interruptTime = Get-CounterMetric -CounterPaths @(
        "\Processor Information(_Total)\% Interrupt Time",
        "\Processor(_Total)\% Interrupt Time"
    )

    return [PSCustomObject]@{
        DpcTimePercent = if ($dpcTime) { $dpcTime.Value } else { $null }
        InterruptTimePercent = if ($interruptTime) { $interruptTime.Value } else { $null }
    }
}

function Get-DiskActivity {
    $diskBytesPerSecond = Get-CounterMetric -CounterPaths @("\PhysicalDisk(_Total)\Disk Bytes/sec")

    if ($diskBytesPerSecond) {
        return [math]::Round($diskBytesPerSecond.Value / 1MB, 2)
    }

    return $null
}

function Get-NetworkActivity {
    $networkBytesPerSecond = Get-CounterMetric `
        -CounterPaths @("\Network Interface(*)\Bytes Total/sec") `
        -Aggregate "Sum" `
        -Filter { $_.InstanceName -notmatch "Loopback|isatap|Teredo" }

    if ($networkBytesPerSecond) {
        return [math]::Round($networkBytesPerSecond.Value / 1MB, 2)
    }

    return $null
}

function Get-CpuScalingPercent {
    param(
        $CpuPerformance,
        $FallbackClockPercent
    )

    $scalingValues = @()
    if ($CpuPerformance) {
        if ($null -ne $CpuPerformance.PerformancePercent) {
            $scalingValues += [double]$CpuPerformance.PerformancePercent
        }
        if ($null -ne $CpuPerformance.FrequencyPercent) {
            $scalingValues += [double]$CpuPerformance.FrequencyPercent
        }
    }

    if ($scalingValues.Count -gt 0) {
        return [math]::Round(($scalingValues | Measure-Object -Minimum).Minimum, 2)
    }

    if ($null -ne $FallbackClockPercent) {
        return [double]$FallbackClockPercent
    }

    return $null
}

# Enhanced throttling detection
function Test-ThermalThrottling {
    param(
        $CpuLoadPercent,
        $CpuTemperature,
        $CpuPerformance
    )

    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop
    } catch {
        Write-Log "Unable to get CPU clock data: $_"
        return @{
            IsThrottling = $false
            LowClock = $false
            CurrentClock = $null
            MaxClock = $null
            Percentage = $null
            PerformancePercent = if ($CpuPerformance) { $CpuPerformance.PerformancePercent } else { $null }
            FrequencyPercent = if ($CpuPerformance) { $CpuPerformance.FrequencyPercent } else { $null }
            ScalingPercent = Get-CpuScalingPercent -CpuPerformance $CpuPerformance -FallbackClockPercent $null
            CpuLoadPercent = $CpuLoadPercent
            TemperatureMax = $null
            Reason = "CPU clock data unavailable"
        }
    }

    $currentClock = [math]::Round(($cpu | Measure-Object -Property CurrentClockSpeed -Average).Average, 0)
    $maxClock = ($cpu | Measure-Object -Property MaxClockSpeed -Maximum).Maximum

    if (-not $maxClock -or $maxClock -le 0) {
        return @{
            IsThrottling = $false
            LowClock = $false
            CurrentClock = $currentClock
            MaxClock = $maxClock
            Percentage = $null
            PerformancePercent = if ($CpuPerformance) { $CpuPerformance.PerformancePercent } else { $null }
            FrequencyPercent = if ($CpuPerformance) { $CpuPerformance.FrequencyPercent } else { $null }
            ScalingPercent = Get-CpuScalingPercent -CpuPerformance $CpuPerformance -FallbackClockPercent $null
            CpuLoadPercent = $CpuLoadPercent
            TemperatureMax = $null
            Reason = "Maximum CPU clock unavailable"
        }
    }

    $throttlePercent = [math]::Round(($currentClock / $maxClock) * 100, 2)
    $temperatureMax = if ($CpuTemperature -and $null -ne $CpuTemperature.Max) { [double]$CpuTemperature.Max } else { $null }
    $performancePercent = if ($CpuPerformance -and $null -ne $CpuPerformance.PerformancePercent) { [double]$CpuPerformance.PerformancePercent } else { $null }
    $frequencyPercent = if ($CpuPerformance -and $null -ne $CpuPerformance.FrequencyPercent) { [double]$CpuPerformance.FrequencyPercent } else { $null }
    $scalingPercent = Get-CpuScalingPercent -CpuPerformance $CpuPerformance -FallbackClockPercent $throttlePercent
    $hasHighLoad = ($null -ne $CpuLoadPercent -and [double]$CpuLoadPercent -ge 75)
    $hasHighTemperature = ($null -ne $temperatureMax -and $temperatureMax -ge 85)
    $lowClock = ($null -ne $scalingPercent -and $scalingPercent -lt 85)
    $isThermalThrottling = ($lowClock -and $hasHighLoad -and $hasHighTemperature)

    $reason = if ($isThermalThrottling) {
        "Reduced CPU performance under high CPU load and high temperature"
    } elseif ($lowClock) {
        "Reduced CPU performance observed without enough thermal evidence"
    } else {
        "CPU performance is within expected range"
    }
    
    return @{
        IsThrottling = $isThermalThrottling
        LowClock = $lowClock
        CurrentClock = $currentClock
        MaxClock = $maxClock
        Percentage = $throttlePercent
        PerformancePercent = $performancePercent
        FrequencyPercent = $frequencyPercent
        ScalingPercent = $scalingPercent
        CpuLoadPercent = $CpuLoadPercent
        TemperatureMax = $temperatureMax
        Reason = $reason
    }
}

# Function to analyze and rank heat-causing processes
function Get-HeatCulprits {
    param(
        $ProcessHistory,
        $TemperatureHistory,
        $ThrottleEvents,
        $SystemTelemetryHistory,
        $TotalIterations
    )
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "           HEAT ANALYSIS REPORT                " -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Red
    Write-Host ""
    
    Write-Log ""
    Write-Log "===== HEAT ANALYSIS REPORT ====="
    
    # Calculate average CPU usage per process
    $processAverages = @{}
    foreach ($process in $ProcessHistory.Keys) {
        $cpuSampleCount = $ProcessHistory[$process].CPU.Count
        $gpuSampleCount = if ($ProcessHistory[$process].ContainsKey("GPU")) { $ProcessHistory[$process].GPU.Count } else { 0 }
        $ioSampleCount = if ($ProcessHistory[$process].ContainsKey("IO")) { $ProcessHistory[$process].IO.Count } else { 0 }

        $avgCPU = if ($cpuSampleCount -gt 0) {
            ($ProcessHistory[$process].CPU | Measure-Object -Average).Average
        } else { 0 }
        
        $maxCPU = if ($cpuSampleCount -gt 0) {
            ($ProcessHistory[$process].CPU | Measure-Object -Maximum).Maximum
        } else { 0 }

        $avgGPU = if ($gpuSampleCount -gt 0) {
            ($ProcessHistory[$process].GPU | Measure-Object -Average).Average
        } else { 0 }

        $maxGPU = if ($gpuSampleCount -gt 0) {
            ($ProcessHistory[$process].GPU | Measure-Object -Maximum).Maximum
        } else { 0 }

        $avgIO = if ($ioSampleCount -gt 0) {
            ($ProcessHistory[$process].IO | Measure-Object -Average).Average
        } else { 0 }

        $maxIO = if ($ioSampleCount -gt 0) {
            ($ProcessHistory[$process].IO | Measure-Object -Maximum).Maximum
        } else { 0 }
        
        $avgMem = if ($ProcessHistory[$process].Memory.Count -gt 0) {
            ($ProcessHistory[$process].Memory | Measure-Object -Average).Average
        } else { 0 }
        
        $frequency = [math]::Max([math]::Max($cpuSampleCount, $gpuSampleCount), $ioSampleCount)
        $frequencyPercent = ($frequency / $TotalIterations) * 100
        $cpuFrequencyPercent = ($cpuSampleCount / $TotalIterations) * 100
        $gpuFrequencyPercent = ($gpuSampleCount / $TotalIterations) * 100
        $ioFrequencyPercent = ($ioSampleCount / $TotalIterations) * 100
        
        # Improved heat score calculation:
        # - Average CPU * duration factor (sustained load)
        # - Average GPU * duration factor (shared cooling impact)
        # - Peak CPU impact
        # - Memory pressure consideration
        $sustainedCpuLoad = $avgCPU * ($cpuFrequencyPercent / 100)  # CPU% × time presence
        $sustainedGpuLoad = $avgGPU * ($gpuFrequencyPercent / 100)  # GPU% × time presence
        $peakLoad = ($maxCPU * 0.3) + ($maxGPU * 0.2)  # Peak spikes matter less
        $gpuPressure = $sustainedGpuLoad * 0.7
        $ioPressure = [math]::Min(($avgIO / 25), 15) * ($ioFrequencyPercent / 100)
        $memoryPressure = [math]::Min($avgMem / 1000, 10)  # Cap memory contribution at 10 points
        
        $processAverages[$process] = @{
            AvgCPU = [math]::Round($avgCPU, 2)
            MaxCPU = [math]::Round($maxCPU, 2)
            AvgGPU = [math]::Round($avgGPU, 2)
            MaxGPU = [math]::Round($maxGPU, 2)
            AvgIOMBps = [math]::Round($avgIO, 2)
            MaxIOMBps = [math]::Round($maxIO, 2)
            AvgMemoryMB = [math]::Round($avgMem, 2)
            Frequency = $frequency
            FrequencyPercent = [math]::Round($frequencyPercent, 1)
            CpuSamples = $cpuSampleCount
            GpuSamples = $gpuSampleCount
            IoSamples = $ioSampleCount
            HeatScore = [math]::Round($sustainedCpuLoad + $gpuPressure + $peakLoad + $ioPressure + $memoryPressure, 2)
        }
    }
    
    # Sort by heat score
    $topCulprits = $processAverages.GetEnumerator() | 
        Where-Object { $_.Value.HeatScore -gt 0 } |
        Sort-Object { $_.Value.HeatScore } -Descending | 
        Select-Object -First 5
    
    Write-Host "🔥 TOP HEAT-CAUSING PROCESSES:" -ForegroundColor Yellow
    Write-Log "Top Heat-Causing Processes (ranked by heat score):"
    
    $rank = 1
    foreach ($culprit in $topCulprits) {
        $color = if ($culprit.Value.HeatScore -gt 50) { "Red" } 
                 elseif ($culprit.Value.HeatScore -gt 25) { "Yellow" } 
                 else { "White" }
                 
        Write-Host "  $rank. $($culprit.Key)" -ForegroundColor $color
        $heatScoreText = "     Heat Score: $($culprit.Value.HeatScore) | Avg CPU: $($culprit.Value.AvgCPU)% | Max CPU: $($culprit.Value.MaxCPU)%"
        Write-Host $heatScoreText -ForegroundColor $color
        if ($culprit.Value.AvgGPU -gt 0 -or $culprit.Value.MaxGPU -gt 0) {
            $gpuText = "     GPU: Avg $($culprit.Value.AvgGPU)% | Max $($culprit.Value.MaxGPU)%"
            Write-Host $gpuText -ForegroundColor $color
        }
        if ($culprit.Value.AvgIOMBps -gt 0 -or $culprit.Value.MaxIOMBps -gt 0) {
            $ioText = "     I/O: Avg $($culprit.Value.AvgIOMBps) MB/s | Max $($culprit.Value.MaxIOMBps) MB/s"
            Write-Host $ioText -ForegroundColor $color
        }
        $memoryText = "     Memory: $($culprit.Value.AvgMemoryMB) MB | Present: $($culprit.Value.FrequencyPercent)% of time"
        Write-Host $memoryText -ForegroundColor Gray
        
        Write-Log "  $rank. $($culprit.Key) - Heat Score: $($culprit.Value.HeatScore)"
        $avgCpuLogText = "     Average CPU: $($culprit.Value.AvgCPU)%, Max CPU: $($culprit.Value.MaxCPU)%"
        Write-Log $avgCpuLogText
        if ($culprit.Value.AvgGPU -gt 0 -or $culprit.Value.MaxGPU -gt 0) {
            $avgGpuLogText = "     Average GPU: $($culprit.Value.AvgGPU)%, Max GPU: $($culprit.Value.MaxGPU)%"
            Write-Log $avgGpuLogText
        }
        if ($culprit.Value.AvgIOMBps -gt 0 -or $culprit.Value.MaxIOMBps -gt 0) {
            $avgIoLogText = "     Average I/O: $($culprit.Value.AvgIOMBps) MB/s, Max I/O: $($culprit.Value.MaxIOMBps) MB/s"
            Write-Log $avgIoLogText
        }
        Write-Log "     Average Memory: $($culprit.Value.AvgMemoryMB) MB"
        $presenceLogText = "     Presence: $($culprit.Value.Frequency)/$TotalIterations cycles ($($culprit.Value.FrequencyPercent)%)"
        Write-Log $presenceLogText
        Write-Log "     Samples: CPU $($culprit.Value.CpuSamples), GPU $($culprit.Value.GpuSamples), I/O $($culprit.Value.IoSamples)"
        $rank++
    }
    
    # Temperature analysis
    if ($TemperatureHistory.Count -gt 0) {
        $averageTemperatureSamples = @($TemperatureHistory | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains "Average") { $_.Average } else { $_ }
        } | Where-Object { $null -ne $_ })
        $maxTemperatureSamples = @($TemperatureHistory | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains "Max") { $_.Max } else { $_ }
        } | Where-Object { $null -ne $_ })
        $powerSamples = @($TemperatureHistory | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains "PowerWatts") { $_.PowerWatts }
        } | Where-Object { $null -ne $_ })
        $fanSamples = @($TemperatureHistory | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains "FanRPM") { $_.FanRPM }
        } | Where-Object { $null -ne $_ })

        $avgSystemTemp = if ($averageTemperatureSamples.Count -gt 0) {
            ($averageTemperatureSamples | Measure-Object -Average).Average
        } else {
            ($maxTemperatureSamples | Measure-Object -Average).Average
        }

        $maxSystemTemp = if ($maxTemperatureSamples.Count -gt 0) {
            ($maxTemperatureSamples | Measure-Object -Maximum).Maximum
        } else {
            ($averageTemperatureSamples | Measure-Object -Maximum).Maximum
        }
        
        Write-Host ""
        Write-Host "TEMPERATURE SUMMARY:" -ForegroundColor Cyan
        $avgTempC = [math]::Round($avgSystemTemp, 1)
        $avgTempF = ConvertTo-Fahrenheit $avgTempC
        $avgTempText = "   Average: $avgTempC°C ($avgTempF°F)"
        Write-Host $avgTempText -ForegroundColor White
        $maxTempC = [math]::Round($maxSystemTemp, 1)
        $maxTempF = ConvertTo-Fahrenheit $maxTempC
        $maxTempText = "   Maximum: $maxTempC°C ($maxTempF°F)"
        Write-Host $maxTempText -ForegroundColor $(if ($maxSystemTemp -gt 85) { "Red" } else { "White" })
        
        Write-Log ""
        Write-Log "Temperature Summary:"
        $avgTempLog = "  Average Temperature: $avgTempC°C ($avgTempF°F)"
        Write-Log $avgTempLog
        $maxTempLog = "  Maximum Temperature: $maxTempC°C ($maxTempF°F)"
        Write-Log $maxTempLog

        if ($powerSamples.Count -gt 0) {
            $avgPowerWatts = [math]::Round(($powerSamples | Measure-Object -Average).Average, 1)
            $maxPowerWatts = [math]::Round(($powerSamples | Measure-Object -Maximum).Maximum, 1)
            $powerText = "   CPU Power: Avg $avgPowerWatts W | Max $maxPowerWatts W"
            Write-Host $powerText -ForegroundColor White
            Write-Log "  CPU Power: Average $avgPowerWatts W, Maximum $maxPowerWatts W"
        }

        if ($fanSamples.Count -gt 0) {
            $avgFanRpm = [math]::Round(($fanSamples | Measure-Object -Average).Average, 0)
            $fanText = "   Fan: Avg $avgFanRpm RPM"
            Write-Host $fanText -ForegroundColor White
            Write-Log "  Fan Speed: Average $avgFanRpm RPM"
        }
        
        if ($maxSystemTemp -gt 85) {
            Write-Host "   ⚠️ HIGH TEMPERATURE DETECTED!" -ForegroundColor Red
            Write-Log "  WARNING: High temperature detected (greater than 85°C / 185°F)"
        }
    } else {
        Write-Host ""
        Write-Host "🌡️ No temperature data available" -ForegroundColor Gray
        Write-Log "No temperature sensors accessible during monitoring"
    }

    # System-level activity that may explain heat without a single obvious app culprit
    if ($SystemTelemetryHistory.Count -gt 0) {
        Write-Host ""
        Write-Host "SYSTEM SIGNALS SUMMARY:" -ForegroundColor Cyan
        Write-Log ""
        Write-Log "System Signals Summary:"

        $telemetryMetrics = @(
            @{ Name = "CPU performance"; Property = "CpuPerformancePercent"; Unit = "%"; Warning = $null },
            @{ Name = "CPU max frequency"; Property = "CpuFrequencyPercent"; Unit = "%"; Warning = $null },
            @{ Name = "DPC time"; Property = "DpcTimePercent"; Unit = "%"; Warning = 5 },
            @{ Name = "Interrupt time"; Property = "InterruptTimePercent"; Unit = "%"; Warning = 5 },
            @{ Name = "Disk throughput"; Property = "DiskMBps"; Unit = " MB/s"; Warning = 50 },
            @{ Name = "Network throughput"; Property = "NetworkMBps"; Unit = " MB/s"; Warning = 20 }
        )

        foreach ($metric in $telemetryMetrics) {
            $samples = @($SystemTelemetryHistory | ForEach-Object { $_.($metric.Property) } | Where-Object { $null -ne $_ })
            if ($samples.Count -eq 0) {
                continue
            }

            $averageValue = [math]::Round(($samples | Measure-Object -Average).Average, 2)
            $maximumValue = [math]::Round(($samples | Measure-Object -Maximum).Maximum, 2)
            $metricText = "   $($metric.Name): Avg $averageValue$($metric.Unit) | Max $maximumValue$($metric.Unit)"
            $metricColor = if ($null -ne $metric.Warning -and $maximumValue -ge $metric.Warning) { "Yellow" } else { "White" }
            Write-Host $metricText -ForegroundColor $metricColor
            Write-Log "  $($metric.Name): Average $averageValue$($metric.Unit), Maximum $maximumValue$($metric.Unit)"
        }

        $maxDpc = ($SystemTelemetryHistory | ForEach-Object { $_.DpcTimePercent } | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum
        $maxInterrupt = ($SystemTelemetryHistory | ForEach-Object { $_.InterruptTimePercent } | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum
        if (($null -ne $maxDpc -and $maxDpc -ge 5) -or ($null -ne $maxInterrupt -and $maxInterrupt -ge 5)) {
            Write-Host "   ⚠️ Elevated driver/kernel activity detected" -ForegroundColor Yellow
            Write-Log "  WARNING: Elevated DPC/interrupt activity may point to driver or device-related heat"
        }
    }
    
    # Throttling analysis
    if ($ThrottleEvents.Count -gt 0) {
        $throttleRate = [math]::Round(($ThrottleEvents.Count / $TotalIterations) * 100, 1)
        Write-Host ""
        $throttleMessage = "⚡ THROTTLING EVENTS: $($ThrottleEvents.Count)/$TotalIterations cycles ($throttleRate%)"
        Write-Host $throttleMessage -ForegroundColor $(if ($throttleRate -gt 50) { "Red" } else { "Yellow" })
        Write-Log ""
        $throttleLogMessage = "Throttling Events: $($ThrottleEvents.Count)/$TotalIterations cycles ($throttleRate%)"
        Write-Log $throttleLogMessage
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Red
    Write-Log "===== END OF HEAT ANALYSIS ====="
}

# Main monitoring loop
Write-Host "===============================================" -ForegroundColor Green
Write-Host "           THERMAL MONITOR STARTED            " -ForegroundColor Green
Write-Host "===============================================" -ForegroundColor Green
Write-Host ""
Write-Host "📊 Monitoring System Performance..." -ForegroundColor Yellow
Write-Host "📁 Log file location: $logFile" -ForegroundColor Cyan
Write-Host "⏱️ Duration: 5 minutes (30 cycles, 10s intervals)" -ForegroundColor Cyan
Write-Host "🌡️ For best temperature, power, and fan data, run LibreHardwareMonitor or Open Hardware Monitor first." -ForegroundColor White
Write-Host "💡 Check the log file for detailed results!" -ForegroundColor White
Write-Host ""

Write-Log "Starting thermal monitoring..."

$script:monitorDuration = 300 # Monitor for 5 minutes (300 seconds)
$script:interval = 10 # Check every 10 seconds
$script:iterations = [math]::Ceiling($monitorDuration / $interval)

for ($i = 1; $i -le $iterations; $i++) {
    # Show progress
    Show-Progress -CurrentIteration $i -TotalIterations $iterations -Activity "Cycle $i of $iterations"
    Write-Host ""
    
    Write-Log "----- Monitoring Cycle $i -----"

    # Show spinning animation while collecting data
    Show-SpinningCursor -Index $i
    Start-Sleep -Milliseconds 500
    
    # Get CPU usage
    $cpuProcesses = Get-TopCpuProcesses
    Write-Log "Top CPU-consuming processes:"
    if ($cpuProcesses) {
        $cpuProcesses | ForEach-Object {
            # Track process history for heat analysis
            if (-not $script:processHistory.ContainsKey($_.Name)) {
                $script:processHistory[$_.Name] = @{ CPU = @(); Memory = @(); GPU = @(); IO = @() }
            }
            
            if ($_.CPUPercent) {
                $script:processHistory[$_.Name].CPU += $_.CPUPercent
                $script:processHistory[$_.Name].Memory += $_.WorkingSetMB
                $processLogText = "  Process: $($_.Name), CPU: $($_.CPUPercent)%, Memory: $($_.WorkingSetMB)MB, Threads: $($_.ThreadCount)"
                Write-Log $processLogText
            } else {
                Write-Log "  Process: $($_.Name), PID: $($_.ID), CPU Time: $($_.CPUTime)s, Memory: $($_.WorkingSetMB)MB"
            }
        }
    }

    $totalCpuUsage = Get-TotalCpuUsage
    if ($null -ne $totalCpuUsage) {
        Write-Log "Total CPU usage: $totalCpuUsage%"
    }

    $cpuPerformance = Get-CpuPerformanceTelemetry
    if ($cpuPerformance.PerformancePercent -or $cpuPerformance.FrequencyPercent) {
        $performanceText = if ($null -ne $cpuPerformance.PerformancePercent) { "$($cpuPerformance.PerformancePercent)% processor performance" } else { "processor performance unavailable" }
        $frequencyText = if ($null -ne $cpuPerformance.FrequencyPercent) { "$($cpuPerformance.FrequencyPercent)% maximum frequency" } else { "maximum frequency unavailable" }
        Write-Log "CPU performance telemetry: $performanceText; $frequencyText"
    }

    $kernelActivity = Get-KernelActivity
    Write-Log "Kernel activity: DPC $($kernelActivity.DpcTimePercent)%; Interrupt $($kernelActivity.InterruptTimePercent)%"

    $diskMBps = Get-DiskActivity
    if ($null -ne $diskMBps) {
        Write-Log "Disk throughput: $diskMBps MB/s"
    }

    $networkMBps = Get-NetworkActivity
    if ($null -ne $networkMBps) {
        Write-Log "Network throughput: $networkMBps MB/s"
    }

    $script:systemTelemetryHistory += [PSCustomObject]@{
        CpuUsagePercent = $totalCpuUsage
        CpuPerformancePercent = $cpuPerformance.PerformancePercent
        CpuFrequencyPercent = $cpuPerformance.FrequencyPercent
        DpcTimePercent = $kernelActivity.DpcTimePercent
        InterruptTimePercent = $kernelActivity.InterruptTimePercent
        DiskMBps = $diskMBps
        NetworkMBps = $networkMBps
    }

    # Get GPU usage
    $gpuUsage = Get-GpuUsage
    if ($gpuUsage) {
        Write-Log "GPU usage information:"
        $gpuUsage | Select-Object -First 5 | ForEach-Object {
            $processIdText = if ($_.ProcessIds) { ", PIDs: $($_.ProcessIds)" } else { "" }
            $engineText = if ($_.EngineTypes) { ", Engines: $($_.EngineTypes)" } else { "" }
            $gpuProcessLogText = "  Process: $($_.Name)$processIdText, GPU Usage: $($_.GPUPercent)%$engineText"
            Write-Log $gpuProcessLogText
            
            # Track GPU usage in process history
            if (-not $script:processHistory.ContainsKey($_.Name)) {
                $script:processHistory[$_.Name] = @{ CPU = @(); Memory = @(); GPU = @(); IO = @() }
            }
            $script:processHistory[$_.Name].GPU += $_.GPUPercent
        }
    }

    # Get process I/O activity
    $ioProcesses = Get-TopIoProcesses
    if ($ioProcesses) {
        Write-Log "Top process I/O activity:"
        $ioProcesses | Select-Object -First 5 | ForEach-Object {
            if (-not $script:processHistory.ContainsKey($_.Name)) {
                $script:processHistory[$_.Name] = @{ CPU = @(); Memory = @(); GPU = @(); IO = @() }
            }
            $script:processHistory[$_.Name].IO += $_.IOMBps
            $ioProcessLogText = "  Process: $($_.Name), I/O: $($_.IOMBps) MB/s"
            Write-Log $ioProcessLogText
        }
    }

    # Get CPU temperature
    $cpuTemp = Get-CpuTemperature
    if ($cpuTemp) {
        Write-Log "CPU Temperature ($($cpuTemp.Source)):"
        $script:temperatureHistory += [PSCustomObject]@{
            Average = $cpuTemp.Average
            Max = $cpuTemp.Max
            PowerWatts = $cpuTemp.PowerWatts
            FanRPM = $cpuTemp.FanRPM
            Source = $cpuTemp.Source
        }
        $tempLogText = "  Average: $($cpuTemp.Average)°C ($($cpuTemp.AverageF)°F), Max: $($cpuTemp.Max)°C ($($cpuTemp.MaxF)°F)"
        Write-Log $tempLogText
        if ($null -ne $cpuTemp.PowerWatts) {
            Write-Log "  CPU Package Power: $($cpuTemp.PowerWatts) W average, $($cpuTemp.MaxPowerWatts) W max"
        }
        if ($null -ne $cpuTemp.FanRPM) {
            Write-Log "  Fan Speed: $($cpuTemp.FanRPM) RPM average"
        }
        
        # Show temperature warning in console
        if ($cpuTemp.Max -gt 85) {
            $highTempText = "`rWARNING: HIGH TEMP: $($cpuTemp.Max)°C ($($cpuTemp.MaxF)°F)"
            Write-Host $highTempText -ForegroundColor Red
        }
        
        if ($cpuTemp.Details -and $cpuTemp.Details -isnot [string]) {
            $cpuTemp.Details | ForEach-Object {
                $detailTempLogText = "  $($_.Name): $($_.Value)°C ($($_.ValueF)°F)"
                Write-Log $detailTempLogText
            }
        }
    } else {
        Write-Log "No temperature sensors accessible"
    }

    # Check for throttling
    $throttleStatus = Test-ThermalThrottling -CpuLoadPercent $totalCpuUsage -CpuTemperature $cpuTemp -CpuPerformance $cpuPerformance
    $loadText = if ($null -ne $throttleStatus.CpuLoadPercent) { "$($throttleStatus.CpuLoadPercent)%" } else { "unknown" }
    $tempText = if ($null -ne $throttleStatus.TemperatureMax) { "$($throttleStatus.TemperatureMax)°C" } else { "unknown" }
    $scalingText = if ($null -ne $throttleStatus.ScalingPercent) { "$($throttleStatus.ScalingPercent)%" } else { "unknown" }

    if ($throttleStatus.IsThrottling) {
        $script:throttleEvents += $i
        $throttleLogText = "THERMAL THROTTLING LIKELY: CPU scaling: $scalingText; Current clock: $($throttleStatus.CurrentClock) MHz, Max: $($throttleStatus.MaxClock) MHz ($($throttleStatus.Percentage)%); CPU load: $loadText; Max temp: $tempText"
        Write-Log $throttleLogText
        $throttleConsoleText = "`r⚡ Throttling likely at $scalingText CPU scaling"
        Write-Host $throttleConsoleText -ForegroundColor Yellow
    } elseif ($throttleStatus.LowClock) {
        $lowClockLogText = "Reduced CPU performance observed but not classified as thermal throttling: CPU scaling: $scalingText; Current clock: $($throttleStatus.CurrentClock) MHz, Max: $($throttleStatus.MaxClock) MHz ($($throttleStatus.Percentage)%); CPU load: $loadText; Max temp: $tempText; Reason: $($throttleStatus.Reason)"
        Write-Log $lowClockLogText
    } else {
        $noThrottleLogText = "No thermal throttling: CPU scaling: $scalingText; Current clock: $($throttleStatus.CurrentClock) MHz ($($throttleStatus.Percentage)% of max); CPU load: $loadText; Max temp: $tempText"
        Write-Log $noThrottleLogText
    }

    # Clear the spinning cursor and show completion
    Write-Host "`rCycle $i/$iterations completed ✓" -ForegroundColor Green
    
    # Wait for the next interval
    if ($i -lt $iterations) {
        Start-Sleep -Seconds ($interval - 1)
    }
}

# Analyze and report heat culprits
Get-HeatCulprits -ProcessHistory $script:processHistory -TemperatureHistory $script:temperatureHistory -ThrottleEvents $script:throttleEvents -SystemTelemetryHistory $script:systemTelemetryHistory -TotalIterations $script:iterations

Write-Log ""
Write-Log "Monitoring complete. Log saved to $logFile"

Write-Host ""
Write-Host "===============================================" -ForegroundColor Green
Write-Host "         MONITORING COMPLETED! ✓              " -ForegroundColor Green
Write-Host "===============================================" -ForegroundColor Green
Write-Host ""
Write-Host "📁 Full log saved to: $logFile" -ForegroundColor Cyan
Write-Host "🔍 Open the log file to review detailed results" -ForegroundColor White
Write-Host ""