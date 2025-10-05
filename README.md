# Decrypt-ColorNoteBackup.ps1

This script converts notes from ColorNote, an Android application, to a JSON file.

## Description

This script decrypts backup files from the ColorNote app. It reads an encrypted backup file, processes the notes, and saves them as a clean JSON file. Optionally, it can also export all the notes into a single Joplin Export (JEX) file, ready for import into other applications.

When executed, the script will prompt for a password. If you press Enter without typing a password, it will default to `"0000"`, which is the default password for automatic backups.

## Requirements

This script requires PowerShell 7 to run correctly.

## Parameters

* `-InputFile` (string, Mandatory): The path to the encrypted ColorNote backup file.
* `-OutputFile` (string, Mandatory): The path where the decrypted JSON content will be saved.
* `-Offset` (int, Optional): The number of bytes to skip at the beginning of the input file before decryption begins. Defaults to `28`.
* `-JexOutputFile` (string, Optional): The path where the decrypted content will be saved as a Joplin Export (JEX) file.

## Example Usage

```powershell
.\Decrypt-ColorNoteBackup.ps1 -InputFile .\my_backup.db -OutputFile .\decrypted_notes.json -JexOutputFile .\colornote_export.jex
```

## Acknowledgements

The decryption part of this script is inspired by the Java tool [ColorNote-backup-decryptor](https://github.com/olejorgenb/ColorNote-backup-decryptor) by olejorgenb.
