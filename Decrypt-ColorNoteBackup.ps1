<#
.SYNOPSIS
    Decrypts a ColorNote backup file.
.DESCRIPTION
    This script decrypts a file that was encrypted using the PBEWITHMD5AND128BITAES-CBC-OPENSSL algorithm,
    which is used by ColorNote for its backups.
.PARAMETER InputFile
    The path to the encrypted ColorNote backup file.
.PARAMETER OutputFile
    The path where the decrypted content will be saved (in JSON format).
.PARAMETER Offset
    The number of bytes to skip at the beginning of the input file before decryption begins. Defaults to 28.
.PARAMETER JexOutputFile
    The path where the decrypted content will be saved as a Joplin Export (JEX) file.
.EXAMPLE
    PS > .\Decrypt-ColorNoteBackup.ps1 -InputFile .\my_backup.db -OutputFile .\decrypted_notes.txt -JexOutputFile .\colornote_export.jex
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [int]$Offset = 28,

    [string]$JexOutputFile # New parameter for JEX output
)

function Get-OpenSslDerivedBytes {
    param(
        [string]$Password,
        [byte[]]$Salt
    )

    $passwordBytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $md5 = [System.Security.Cryptography.MD5]::Create()

    # The key derivation mimics OpenSSL's EVP_BytesToKey function.
    # First hash provides the key.
    $combined1 = New-Object byte[] ($passwordBytes.Length + $Salt.Length)
    [System.Buffer]::BlockCopy($passwordBytes, 0, $combined1, 0, $passwordBytes.Length)
    [System.Buffer]::BlockCopy($Salt, 0, $combined1, $passwordBytes.Length, $Salt.Length)
    $key = $md5.ComputeHash($combined1)

    # Second hash, using the result of the first, provides the IV.
    # NOTE: This derived IV is known to be incorrect for this specific implementation,
    # but we must provide one. The resulting garbage in the first block is handled later.
    $combined2 = New-Object byte[] ($key.Length + $passwordBytes.Length + $Salt.Length)
    [System.Buffer]::BlockCopy($key, 0, $combined2, 0, $key.Length)
    [System.Buffer]::BlockCopy($passwordBytes, 0, $combined2, $key.Length, $passwordBytes.Length)
    [System.Buffer]::BlockCopy($Salt, 0, $combined2, ($key.Length + $passwordBytes.Length), $Salt.Length)
    $iv = $md5.ComputeHash($combined2)

    $md5.Dispose()

    return [PSCustomObject]@{ 
        Key = $key
        IV  = $iv
    }
}

$aes = $null
$decryptor = $null
$inputMemoryStream = $null
$cryptoStream = $null
$outputMemoryStream = $null

try {
    # Verify the input file exists before proceeding.
    if (-not (Test-Path -Path $InputFile -PathType Leaf)) {
        throw "Input file not found: $InputFile"
    }

    # Prompt for password
    $securePassword = Read-Host -Prompt "Enter password (press Enter for default '0000')" -AsSecureString
    if ($securePassword.Length -eq 0) {
        $Password = "0000"
    }
    else {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    # The salt is a fixed string.
    $salt = [System.Text.Encoding]::UTF8.GetBytes("ColorNote Fixed Salt")

    # Derive the AES key and IV from the password and salt.
    $derived = Get-OpenSslDerivedBytes -Password $Password -Salt $salt

    # Read the encrypted file content from disk.
    $fileBytes = [System.IO.File]::ReadAllBytes($InputFile)
    
    # If the offset is out of bounds, there's nothing to decrypt.
    if ($Offset -ge $fileBytes.Length) {
        throw "Offset is greater than or equal to the file length. No data to decrypt."
    }
    # Apply the offset to get the actual encrypted payload.
    $encryptedBytes = $fileBytes[$Offset..($fileBytes.Length - 1)]

    # Configure the AES decryption algorithm.
    $aes = [System.Security.Cryptography.AesManaged]::new()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.KeySize = 128
    $aes.BlockSize = 128
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $derived.Key
    $aes.IV = $derived.IV

    # Create a decryptor and streams for processing.
    $decryptor = $aes.CreateDecryptor()
    $inputMemoryStream = [System.IO.MemoryStream]::new($encryptedBytes)
    $cryptoStream = [System.Security.Cryptography.CryptoStream]::new($inputMemoryStream, $decryptor, [System.Security.Cryptography.CryptoStreamMode]::Read)
    $outputMemoryStream = [System.IO.MemoryStream]::new()

    # Perform the decryption by copying the crypto stream to a memory stream.
    $cryptoStream.CopyTo($outputMemoryStream)

    $decryptedBytes = $outputMemoryStream.ToArray()

    # Convert the decrypted bytes to a UTF-8 string.
    $decryptedText = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)

    # Use -replace to substitute the separator with a unique placeholder string.
    $separatorPlaceholder = "---JSON-RECORD-SEPARATOR---"
    # The regex looks for two null characters followed by any two characters. The (?s) flag ensures . matches newlines.
    $cleanedText = $decryptedText -replace '(?s)\000\000..', $separatorPlaceholder

    # Split the text into records based on the placeholder.
    $records = $cleanedText.Split(@($separatorPlaceholder), [StringSplitOptions]::None)

    $cleanedObjects = @()
    foreach ($record in $records) {
        $trimmedRecord = $record.Trim()
        if ($trimmedRecord.Length -eq 0) { continue } # Skip empty records that may result from the split

        # Find the first opening and last closing brace to isolate the JSON object.
        $firstBrace = $trimmedRecord.IndexOf('{')
        $lastBrace = $trimmedRecord.LastIndexOf('}')
        if ($firstBrace -ne -1 -and $lastBrace -gt $firstBrace) {
            $cleanedObjects += $trimmedRecord.Substring($firstBrace, $lastBrace - $firstBrace + 1)
        }
    }

    if ($cleanedObjects.Count -gt 0) {
        Write-Host "INFO: Found $($cleanedObjects.Count) JSON objects. Formatting as a JSON array."
        $jsonArrayContent = $cleanedObjects -join ','
        $jsonArray = "[" + $jsonArrayContent + "]"

        # Use ConvertTo-Json to create a well-formed, pretty-printed JSON output.
        try {
            $prettyJson = $jsonArray | ConvertFrom-Json | ConvertTo-Json -Depth 100
            Set-Content -Path $OutputFile -Value $prettyJson -Encoding Utf8BOM
            Write-Host "Decryption and cleanup successful. Output written as a JSON array to $OutputFile"

            # JEX Export Logic
            if (-not [string]::IsNullOrEmpty($JexOutputFile)) {
                Write-Host "INFO: Generating JEX file (Markdown with metadata): $JexOutputFile"

                $tempJexDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
                New-Item -ItemType Directory -Path $tempJexDir | Out-Null
                $resourcesDir = Join-Path $tempJexDir "resources"
                New-Item -ItemType Directory -Path $resourcesDir | Out-Null

                try {
                    $colorNoteNotes = $prettyJson | ConvertFrom-Json

                    # 1. Create Default Notebook
                    $notebookId = [System.Guid]::NewGuid().ToString("N")
                    $notebookTitle = "ColorNote Import"
                    $notebookCreatedTime = [System.DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

                    $notebookMdContent = @"
$($notebookTitle)


id: $($notebookId)
created_time: $($notebookCreatedTime)
updated_time: $($notebookCreatedTime)
user_created_time: $($notebookCreatedTime)
user_updated_time: $($notebookCreatedTime)
encryption_cipher_text: 
encryption_applied: 0
parent_id: 
is_shared: 0
share_id: 
master_key_id: 
icon: 
user_data: 
deleted_time: 0
type_: 2
"@.TrimEnd()
                    Set-Content -Path (Join-Path $tempJexDir "$notebookId.md") -Value $notebookMdContent -Encoding Utf8 -NoNewline

                    # 2. Create Notes
                    foreach ($cnNote in $colorNoteNotes) {
                        if ([string]::IsNullOrEmpty($cnNote.title) -and [string]::IsNullOrEmpty($cnNote.note)) {
                            Write-Host "INFO: Skipping note with empty title and content (ID: $($cnNote._id))"
                            continue
                        }

                        $noteId = [System.Guid]::NewGuid().ToString("N")
                        $mdFileName = "$noteId.md"
                        $mdFilePath = Join-Path $tempJexDir $mdFileName

                        $createdTime = [System.DateTimeOffset]::FromUnixTimeMilliseconds($cnNote.created_date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                        $updatedTime = [System.DateTimeOffset]::FromUnixTimeMilliseconds($cnNote.modified_date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

                        # Decode HTML entities
                        $noteTitle = [System.Net.WebUtility]::HtmlDecode($cnNote.title)
                        $noteBody = [System.Net.WebUtility]::HtmlDecode($cnNote.note)
                        
                        # Add a blank line before horizontal rules to prevent Setext-style headers
                        $noteBody = $noteBody -replace '(?m)^(.+)\n(-{3,})$', "`$1`n`n`$2"

                        if ($cnNote.type -eq 16) {
                            # Checklist
                            $noteBody = $noteBody.Replace("[ ]", "- [ ]")
                        }

                        # Handle Trashed Notes
                        $deletedTime = 0
                        if ($cnNote.active_state -eq 16) {
                            # Use the note's modification date as the deletion time (Unix timestamp ms)
                            $deletedTime = $cnNote.modified_date
                        }

                        $mdBody = @"
$($noteTitle)

$($noteBody)
"@

                        $metadata = @"


id: $noteId
parent_id: $notebookId
created_time: $createdTime
updated_time: $updatedTime
is_conflict: 0
latitude: 0.00000000
longitude: 0.00000000
altitude: 0.0000
author: 
source_url: 
is_todo: 0
todo_due: 0
todo_completed: 0
source: colornote
source_application: colornote-importer
application_data: 
order: 0
user_created_time: $createdTime
user_updated_time: $updatedTime
encryption_cipher_text: 
encryption_applied: 0
markup_language: 1
is_shared: 0
type_: 1
deleted_time: $deletedTime
"@.TrimEnd()
                        $mdContent = $mdBody + $metadata
                        Set-Content -Path $mdFilePath -Value $mdContent -Encoding Utf8 -NoNewline
                    }

                    # 3. Tar everything
                    $tarFile = "$JexOutputFile.tar"
                    $tarCommand = "tar -cvf `"$tarFile`" -C `"$tempJexDir`" *"
                    Invoke-Expression $tarCommand

                    Move-Item -Path $tarFile -Destination $JexOutputFile -Force

                    Write-Host "JEX file successfully created at $JexOutputFile"
                }
                catch {
                    Write-Error "Failed to create JEX file: $_"
                }
                finally {
                    if (Test-Path $tempJexDir) {
                        Remove-Item $tempJexDir -Recurse -Force
                    }
                }
            }
        }
        catch {
            Write-Error "Failed to create final JSON. Writing intermediate cleaned content for debugging."
            Write-Error $_
            Set-Content -Path $OutputFile -Value $jsonArray -Encoding Utf8BOM
        }
    }
    else {
        Write-Warning "Could not find any JSON objects in the decrypted text. Writing raw output."
        Set-Content -Path $OutputFile -Value $decryptedText -Encoding Utf8BOM
    }
}
catch {
    Write-Error "An error occurred during decryption: $_"
}
finally {
    # Ensure all disposable resources are cleaned up.
    if ($aes) { $aes.Dispose() }
    if ($decryptor) { $decryptor.Dispose() }
    if ($inputMemoryStream) { $inputMemoryStream.Dispose() }
    if ($cryptoStream) { $cryptoStream.Dispose() }
    if ($outputMemoryStream) { $outputMemoryStream.Dispose() }
}
