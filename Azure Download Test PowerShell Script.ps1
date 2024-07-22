function Get-FileFromWeb {
    param (
        [Parameter(Mandatory)]
        [string]$URL,

        [Parameter(Mandatory)]
        [string]$File 
    )
    Begin {
        function Show-Progress {
            param (
                [Parameter(Mandatory)]
                [Single]$TotalValue,
        
                [Parameter(Mandatory)]
                [Single]$CurrentValue,
        
                [Parameter(Mandatory)]
                [string]$ProgressText,
        
                [Parameter()]
                [string]$ValueSuffix,
        
                [Parameter()]
                [int]$BarSize = 40,

                [Parameter()]
                [switch]$Complete,
                
                [Parameter()]
                [Single]$SpeedMBps = 0
            )
            
            $SpeedMbps = $SpeedMBps * 8
            $percent = $CurrentValue / $TotalValue
            $percentComplete = $percent * 100
            if ($ValueSuffix) {
                $ValueSuffix = " $ValueSuffix" # add space in front
            }
            if ($psISE) {
                Write-Progress "$ProgressText $CurrentValue$ValueSuffix of $TotalValue$ValueSuffix" -id 0 -percentComplete $percentComplete -CurrentOperation "Speed: $($SpeedMBps.ToString('0.00')) MB/s ($($SpeedMbps.ToString('0.00')) Mbps)"
            }
            else {
                $curBarSize = $BarSize * $percent
                $progbar = ""
                $progbar = $progbar.PadRight($curBarSize,[char]9608)
                $progbar = $progbar.PadRight($BarSize,[char]9617)

                if (!$Complete.IsPresent) {
                    Write-Host -NoNewLine "`r$ProgressText $progbar [ $($CurrentValue.ToString("#.###").PadLeft($TotalValue.ToString("#.###").Length))$ValueSuffix / $($TotalValue.ToString("#.###"))$ValueSuffix ] $($percentComplete.ToString("##0.00").PadLeft(6)) % complete Speed: $($SpeedMBps.ToString('0.00')) MB/s ($($SpeedMbps.ToString('0.00')) Mbps)"
                }
                else {
                    Write-Host -NoNewLine "`r$ProgressText $progbar [ $($TotalValue.ToString("#.###").PadLeft($TotalValue.ToString("#.###").Length))$ValueSuffix / $($TotalValue.ToString("#.###"))$ValueSuffix ] $($percentComplete.ToString("##0.00").PadLeft(6)) % complete Speed: $($SpeedMBps.ToString('0.00')) MB/s ($($SpeedMbps.ToString('0.00')) Mbps)"                    
                }                
            }   
        }

        function Generate-Report {
            param (
                [string]$FilePath,
                [long]$TotalBytes,
                [long]$ElapsedSeconds,
                [Single]$AverageSpeedMBps
            )

            $AverageSpeedMbitsps = $AverageSpeedMBps * 8
            $reportContent = @"
Download Report
---------------
File: $FilePath
Total Size: $([Math]::Round($TotalBytes / 1MB, 2)) MB
Time Taken: $([Math]::Round($ElapsedSeconds, 2)) seconds
Average Speed: $([Math]::Round($AverageSpeedMBps, 2)) MB/s ($([Math]::Round($AverageSpeedMbitsps, 2)) Mbps)
"@

            return $reportContent
        }
    }
    Process {
        try {
            $storeEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'
        
            $request = [System.Net.HttpWebRequest]::Create($URL)
            $response = $request.GetResponse()

            if ($response.StatusCode -eq 401 -or $response.StatusCode -eq 403 -or $response.StatusCode -eq 404) {
                throw "Remote file either doesn't exist, is unauthorized, or is forbidden for '$URL'."
            }

            if($File -match '^\.\\') {
                $File = Join-Path (Get-Location -PSProvider "FileSystem") ($File -Split '^\.')[1]
            }
            
            if($File -and !(Split-Path $File)) {
                $File = Join-Path (Get-Location -PSProvider "FileSystem") $File
            }

            if ($File) {
                $fileDirectory = $([System.IO.Path]::GetDirectoryName($File))
                if (!(Test-Path($fileDirectory))) {
                    [System.IO.Directory]::CreateDirectory($fileDirectory) | Out-Null
                }
            }

            [long]$fullSize = $response.ContentLength
            $fullSizeMB = $fullSize / 1024 / 1024

            [byte[]]$buffer = new-object byte[] 1048576
            [long]$total = [long]$count = 0

            $reader = $response.GetResponseStream()
            $writer = new-object System.IO.FileStream $File, "Create"

            $finalBarCount = 0
            $startTime = [System.DateTime]::Now
            $lastTime = $startTime
            $speedHistory = @()
            $movingAverageSize = 10

            do {
                $count = $reader.Read($buffer, 0, $buffer.Length)
                
                $writer.Write($buffer, 0, $count)
              
                $total += $count
                $totalMB = $total / 1024 / 1024

                $currentTime = [System.DateTime]::Now
                $elapsedTime = ($currentTime - $lastTime).TotalSeconds

                if ($elapsedTime -gt 0) {
                    $bytesRead = $count
                    $speedMBps = ($bytesRead / 1024 / 1024) / $elapsedTime

                    $speedHistory += $speedMBps

                    if ($speedHistory.Count -gt $movingAverageSize) {
                        $speedHistory = $speedHistory[-$movingAverageSize..-1]
                    }

                    $averageSpeedMBps = ($speedHistory | Measure-Object -Average).Average
                }
                else {
                    $averageSpeedMBps = 0
                }

                if ($fullSize -gt 0) {
                    Show-Progress -TotalValue $fullSizeMB -CurrentValue $totalMB -ProgressText "Downloading $($File.Name)" -ValueSuffix "MB" -SpeedMBps $averageSpeedMBps
                }

                if ($total -eq $fullSize -and $count -eq 0 -and $finalBarCount -eq 0) {
                    Show-Progress -TotalValue $fullSizeMB -CurrentValue $totalMB -ProgressText "Downloading $($File.Name)" -ValueSuffix "MB" -Complete -SpeedMBps $averageSpeedMBps
                    $finalBarCount++
                }

                $lastTime = $currentTime

            } while ($count -gt 0)

            # Calculate total elapsed time and average speed
            $endTime = [System.DateTime]::Now
            $totalElapsedSeconds = ($endTime - $startTime).TotalSeconds
            $totalBytesMB = $total / 1024 / 1024
            $averageSpeedMBps = ($totalBytesMB / $totalElapsedSeconds)
            $AverageSpeedMbitsps = $averageSpeedMBps * 8

            # Generate and display report
            $reportContent = Generate-Report -FilePath $File -TotalBytes $total -ElapsedSeconds $totalElapsedSeconds -AverageSpeedMBps $averageSpeedMBps
            $finalReport = "`n$reportContent"
            return $finalReport;

        }

        catch {
            $ExeptionMsg = $_.Exception.Message
            Write-Host "Download breaks with error : $ExeptionMsg"
        }

        finally {
            if ($reader) { $reader.Close() }
            if ($writer) { $writer.Flush(); $writer.Close() }
        
            $ErrorActionPreference = $storeEAP
            [GC]::Collect()
        }    
    }
}


function Get-DownloadFolderPath() {
    $SHGetKnownFolderPathSignature = @'
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public extern static int SHGetKnownFolderPath(
        ref Guid folderId,
        uint flags,
        IntPtr token,
        out IntPtr lpszProfilePath);
'@

    $GetKnownFoldersType = Add-Type -MemberDefinition $SHGetKnownFolderPathSignature -Name 'GetKnownFolders' -Namespace 'SHGetKnownFolderPath' -Using "System.Text" -PassThru
    $folderNameptr = [intptr]::Zero
    [void]$GetKnownFoldersType::SHGetKnownFolderPath([Ref]"374DE290-123F-4565-9164-39C4925E467B", 0, 0, [ref]$folderNameptr)
    $folderName = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($folderNameptr)
    [System.Runtime.InteropServices.Marshal]::FreeCoTaskMem($folderNameptr)
    $folderName
}


function Get-DownloadDetails {
    param (
        [Parameter(Mandatory)]
        [string]$SeedUrl
    )

    # Send HTTP GET request to seed URL
    $response = Invoke-RestMethod -Uri $SeedUrl -Method Get
    $downloadUrl = $response.url

    # Extract region from the seed URL
    $region = $SeedUrl

    # Return the region and download URL as a hashtable
    return @{
        Region = $region
        DownloadUrl = $downloadUrl
    }
}

# Define seed URLs
$seedUrls = @(
    "https://www.azurespeed.com/api/sas?regionName=westeurope&blobName=100MB.bin&operation=download",
    "https://www.azurespeed.com/api/sas?regionName=centralus&blobName=100MB.bin&operation=download",
    "https://www.azurespeed.com/api/sas?regionName=westindia&blobName=100MB.bin&operation=download",
    "https://www.azurespeed.com/api/sas?regionName=eastasia&blobName=100MB.bin&operation=download",
    "https://www.azurespeed.com/api/sas?regionName=uaenorth&blobName=100MB.bin&operation=download",
    "https://www.azurespeed.com/api/sas?regionName=southafricanorth&blobName=100MB.bin&operation=download"
)

# Function to download and generate report for each seed URL
function Download-And-Report {
    param (
        [string]$SeedUrl
    )

    # Get download details
    $details = Get-DownloadDetails -SeedUrl $SeedUrl
    $downloadUrl = $details.DownloadUrl
    $region = $details.Region
    
    # Define the file path
    $downloadFolderPath = Get-DownloadFolderPath
    $filePath = Join-Path -Path $downloadFolderPath -ChildPath "100MB.bin"

    # Download the file
    $report = Get-FileFromWeb -URL $downloadUrl -File $filePath

    # Return the region and report content
    return @{
        Region = $region
        ReportContent = $report
    }
}

# Process each seed URL
$allReports = $seedUrls | ForEach-Object { Download-And-Report -SeedUrl $_ }

# Consolidate reports
$consolidatedReport = @"
Consolidated Download Report
============================
"@

foreach ($report in $allReports) {
    $region = $report.Region
    $reportContent = $report.ReportContent
    $consolidatedReport += "`nRegion: $region`n$reportContent`n"
}

# Save the consolidated report to the download folder
$reportFilePath = Join-Path -Path (Get-DownloadFolderPath) -ChildPath "azure_download_test.txt"
Set-Content -Path $reportFilePath -Value $consolidatedReport
Write-Host $consolidatedReport  -ForegroundColor Magenta
Write-Host "A file named 'azure_download_test.txt' has been create in your download folder. Please send that to BT." -ForegroundColor Green
Write-Host $reportFilePath
Write-Host "We have opened a outlook therad for you. Please click to send." -ForegroundColor Green


# Check if the file exists
if (-Not (Test-Path $reportFilePath)) {
    Write-Host "The report file does not exist at $reportFilePath."  -ForegroundColor Red
    exit
}

try {
    # Create an Outlook application object
    $outlook = New-Object -ComObject Outlook.Application

    # Create a new mail item
    $mail = $outlook.CreateItem(0) # 0 represents a standard email

    # Set the properties of the email
    $mail.Subject = "Azure Load Test Report - Blob Downloads"
    $mail.To = ""
    $mail.Body = "Please find attached the Azure Load Test Report for blob downloads."
    $mail.Attachments.Add($reportFilePath)

    # Display the email draft
    $mail.Display()
}
catch {
    Write-Host "An error occurred: $_" -ForegroundColor Red
}
