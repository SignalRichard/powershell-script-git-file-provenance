[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Path,

    [string] $OutputPath,

    [string] $RepositoryPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('GitCharacterDiff' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;

public static class GitCharacterDiff
{
    public static int[] MapNewToOld(string oldText, string newText)
    {
        var oldChars = ToCodePoints(oldText);
        var newChars = ToCodePoints(newText);
        int oldLength = oldChars.Count, newLength = newChars.Count;
        var mapping = new int[newLength];
        Array.Fill(mapping, -1);

        int prefix = 0;
        while (prefix < oldLength && prefix < newLength && oldChars[prefix] == newChars[prefix])
        {
            mapping[prefix] = prefix;
            prefix++;
        }
        int oldEnd = oldLength, newEnd = newLength;
        while (oldEnd > prefix && newEnd > prefix && oldChars[oldEnd - 1] == newChars[newEnd - 1])
        {
            oldEnd--; newEnd--;
            mapping[newEnd] = oldEnd;
        }
        int n = oldEnd - prefix, m = newEnd - prefix;
        if (n == 0 || m == 0) return mapping;

        int max = n + m;
        int offset = max + 1;
        var v = new int[2 * max + 3];
        v[offset + 1] = 0;
        var trace = new List<int[]>();
        int foundD = -1;

        for (int d = 0; d <= max; d++)
        {
            trace.Add((int[])v.Clone());
            for (int k = -d; k <= d; k += 2)
            {
                int x;
                if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]))
                    x = v[offset + k + 1];
                else
                    x = v[offset + k - 1] + 1;

                int y = x - k;
                while (x < n && y < m && oldChars[prefix + x] == newChars[prefix + y]) { x++; y++; }
                v[offset + k] = x;
                if (x >= n && y >= m) { foundD = d; break; }
            }
            if (foundD >= 0) break;
        }

        int bx = n, by = m;
        for (int d = foundD; d > 0; d--)
        {
            var previous = trace[d];
            int k = bx - by;
            int previousK = (k == -d || (k != d && previous[offset + k - 1] < previous[offset + k + 1])) ? k + 1 : k - 1;
            int previousX = previous[offset + previousK];
            int previousY = previousX - previousK;
            while (bx > previousX && by > previousY)
            {
                mapping[prefix + by - 1] = prefix + bx - 1;
                bx--; by--;
            }
            if (bx == previousX) by--; else bx--;
        }
        while (bx > 0 && by > 0 && oldChars[prefix + bx - 1] == newChars[prefix + by - 1])
        {
            mapping[prefix + by - 1] = prefix + bx - 1;
            bx--; by--;
        }
        return mapping;
    }

    private static List<int> ToCodePoints(string value)
    {
        var result = new List<int>();
        foreach (var rune in value.EnumerateRunes()) result.Add(rune.Value);
        return result;
    }
}
'@
}

function Invoke-GitBytes {
    param([string[]] $GitArguments)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $GitArguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void] $process.Start()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $memory = [System.IO.MemoryStream]::new()
    $process.StandardOutput.BaseStream.CopyTo($memory)
    $process.WaitForExit()
    $stderr = $errorTask.GetAwaiter().GetResult()
    $bytes = $memory.ToArray()
    $memory.Dispose()

    if ($process.ExitCode -ne 0) {
        throw "git $($GitArguments -join ' ') failed: $stderr"
    }
    return ,$bytes
}

function Invoke-GitText {
    param([string[]] $GitArguments)
    $bytes = Invoke-GitBytes -GitArguments $GitArguments
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-GitBlobText {
    param([string] $BlobId, [string] $FilePath)
    $bytes = Invoke-GitBytes -GitArguments @('-C', $repoRoot, 'cat-file', 'blob', $BlobId)
    try { return [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { throw "The committed file is not valid UTF-8: $FilePath" }
}

function Get-GitBlobId {
    param([string] $Revision, [string] $FilePath)
    try {
        return (Invoke-GitText -GitArguments @('-C', $repoRoot, 'rev-parse', '--verify', "$Revision`:$FilePath")).Trim()
    } catch {
        return $null
    }
}

$repoRoot = (Invoke-GitText -GitArguments @('-C', $RepositoryPath, 'rev-parse', '--show-toplevel')).Trim()
$repoRoot = [System.IO.Path]::GetFullPath($repoRoot)
$relativePath = $Path.Replace('\', '/')
if ([System.IO.Path]::IsPathRooted($Path)) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($repoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must be inside the Git repository: $repoRoot"
    }
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $fullPath).Replace('\', '/')
}

$blobId = (Invoke-GitText -GitArguments @('-C', $repoRoot, 'rev-parse', "HEAD:$relativePath")).Trim()
$blobBytes = Invoke-GitBytes -GitArguments @('-C', $repoRoot, 'cat-file', 'blob', $blobId)
try {
    $fileText = [System.Text.UTF8Encoding]::new($false, $true).GetString($blobBytes)
} catch {
    throw "The committed file is not valid UTF-8: $relativePath"
}

$blameText = Invoke-GitText -GitArguments @('-C', $repoRoot, 'blame', '--line-porcelain', '--follow', 'HEAD', '--', $relativePath)
$lineAttributions = [System.Collections.Generic.List[object]]::new()
$current = $null
foreach ($record in ($blameText -split "`n")) {
    $record = $record.TrimEnd("`r")
    if ($record -match '^([0-9a-f]{40,64})\s+\d+\s+(\d+)(?:\s+\d+)?$') {
        $current = [ordered]@{ sha = $Matches[1]; author = $null; authorMail = $null; authorTime = $null; summary = $null; finalLine = [int]$Matches[2] }
        continue
    }
    if ($null -eq $current) { continue }
    if ($record.StartsWith("`t")) {
        $lineAttributions.Add([pscustomobject]$current)
        $current = $null
        continue
    }
    if ($record.StartsWith('author ')) { $current.author = $record.Substring(7) }
    elseif ($record.StartsWith('author-mail ')) { $current.authorMail = $record.Substring(12).Trim('<', '>') }
    elseif ($record.StartsWith('author-time ')) { $current.authorTime = [long]$record.Substring(12) }
    elseif ($record.StartsWith('summary ')) { $current.summary = $record.Substring(8) }
}

$historyText = Invoke-GitText -GitArguments @('-C', $repoRoot, 'log', '--follow', '--full-history', '--format=@@%H%x09%P%x09%an%x09%ae%x09%at%x09%s', '--numstat', 'HEAD', '--', $relativePath)
$commitBySha = [ordered]@{}
$userByKey = [ordered]@{}
$commitIndices = @{}
$userIndices = @{}

# The history list includes commits whose changes were later removed and are
# therefore absent from git blame's surviving-line results.
$historyCommit = $null
foreach ($record in ($historyText -split "`n")) {
    $record = $record.TrimEnd("`r")
    if ($record -match '^@@([0-9a-f]{40,64})\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(\d+)\t(.*)$') {
        $historyCommit = [ordered]@{
            sha = $Matches[1]
            parents = @($Matches[2] -split ' ' | Where-Object { $_ })
            author = $Matches[3]
            authorMail = $Matches[4]
            authorTime = [long]$Matches[5]
            summary = $Matches[6]
            addedLines = 0
            removedLines = 0
            removalOnly = $false
        }
        $commitIndices[$historyCommit.sha] = $commitBySha.Count
        $commitBySha[$historyCommit.sha] = $historyCommit
        $userKey = if ($historyCommit.authorMail) { $historyCommit.authorMail } else { $historyCommit.author }
        if (-not $userByKey.Contains($userKey)) {
            $userIndices[$userKey] = $userByKey.Count
            $userByKey[$userKey] = [ordered]@{ id = $userByKey.Count; name = $historyCommit.author; email = $historyCommit.authorMail }
        }
        continue
    }
    if ($historyCommit -and $record -match '^(\d+|-)\t(\d+|-)\t') {
        if ($Matches[1] -ne '-') { $historyCommit.addedLines += [int]$Matches[1] }
        if ($Matches[2] -ne '-') { $historyCommit.removedLines += [int]$Matches[2] }
        $historyCommit.removalOnly = ($historyCommit.addedLines -eq 0 -and $historyCommit.removedLines -gt 0)
    }
}

# Propagate the target path through the commit graph so each parent version can
# be compared, including versions that arrived through a merge or rename.
$graphLines = Invoke-GitText -GitArguments @('-C', $repoRoot, 'rev-list', '--parents', '--topo-order', 'HEAD')
$graphRecords = [System.Collections.Generic.List[object]]::new()
foreach ($record in ($graphLines -split "`n")) {
    $parts = @($record.Trim() -split ' ' | Where-Object { $_ })
    if ($parts.Count -eq 0) { continue }
    $node = [pscustomobject]@{ sha = $parts[0]; parents = @($parts | Select-Object -Skip 1) }
    $graphRecords.Add($node)
}

$headSha = (Invoke-GitText -GitArguments @('-C', $repoRoot, 'rev-parse', 'HEAD')).Trim()
$pathByCommit = @{}
$parentPathByPair = @{}
$pathByCommit[$headSha] = $relativePath
foreach ($node in $graphRecords) {
    if (-not $pathByCommit.ContainsKey($node.sha)) { continue }
    $childPath = $pathByCommit[$node.sha]
    foreach ($parentSha in $node.parents) {
        $parentPath = $childPath
        $nameStatus = Invoke-GitText -GitArguments @('-C', $repoRoot, 'diff-tree', '--no-commit-id', '-r', '-M', '--name-status', $parentSha, $node.sha, '--', $childPath)
        foreach ($change in ($nameStatus -split "`n")) {
            $fields = @($change.TrimEnd("`r") -split "`t")
            if ($fields.Count -ge 3 -and $fields[0] -match '^R\d+$' -and $fields[2] -eq $childPath) {
                $parentPath = $fields[1]
                break
            }
        }
        $parentPathByPair["$($node.sha)|$parentSha"] = $parentPath
        if ($null -ne (Get-GitBlobId -Revision $parentSha -FilePath $parentPath) -and -not $pathByCommit.ContainsKey($parentSha)) {
            $pathByCommit[$parentSha] = $parentPath
        }
    }
}

$remainingChildren = @{}
foreach ($node in $graphRecords) {
    if (-not $pathByCommit.ContainsKey($node.sha)) { continue }
    foreach ($parentSha in $node.parents) {
        if ($pathByCommit.ContainsKey($parentSha)) {
            if (-not $remainingChildren.ContainsKey($parentSha)) { $remainingChildren[$parentSha] = 0 }
            $remainingChildren[$parentSha]++
        }
    }
}

$stateByCommit = @{}
$headOwners = [int[]]::new(0)
for ($nodeIndex = $graphRecords.Count - 1; $nodeIndex -ge 0; $nodeIndex--) {
    $node = $graphRecords[$nodeIndex]
    if (-not $pathByCommit.ContainsKey($node.sha)) { continue }
    $currentPath = $pathByCommit[$node.sha]
    $currentBlobId = Get-GitBlobId -Revision $node.sha -FilePath $currentPath
    if (-not $currentBlobId) { continue }
    $currentText = Get-GitBlobText -BlobId $currentBlobId -FilePath $currentPath
    $newPoints = [System.Collections.Generic.List[int]]::new()
    foreach ($rune in $currentText.EnumerateRunes()) { $newPoints.Add($rune.Value) }
    $candidateMaps = [System.Collections.Generic.List[object]]::new()
    $firstParentBlobId = $null

    for ($parentIndex = 0; $parentIndex -lt $node.parents.Count; $parentIndex++) {
        $parentSha = $node.parents[$parentIndex]
        $parentPath = $parentPathByPair["$($node.sha)|$parentSha"]
        $parentBlobId = Get-GitBlobId -Revision $parentSha -FilePath $parentPath
        if ($parentIndex -eq 0) { $firstParentBlobId = $parentBlobId }
        if (-not $parentBlobId) { continue }
        if (-not $stateByCommit.ContainsKey($parentSha)) { continue }
        $parentState = $stateByCommit[$parentSha]
        if ($parentBlobId -eq $currentBlobId) {
            $mapping = [int[]]::new($newPoints.Count)
            for ($pointIndex = 0; $pointIndex -lt $mapping.Length; $pointIndex++) { $mapping[$pointIndex] = $pointIndex }
        } else {
            $mapping = [GitCharacterDiff]::MapNewToOld($parentState.text, $currentText)
        }
        $candidateMaps.Add([pscustomobject]@{ state = $parentState; mapping = $mapping })
    }

    # Commits visited only to carry history through the graph are not file
    # commits. Add an otherwise-missing merge or root commit only when its
    # resulting file differs from its first parent (or it creates the file).
    $isFileChange = if ($node.parents.Count -eq 0) { $newPoints.Count -gt 0 } else { -not $firstParentBlobId -or $firstParentBlobId -ne $currentBlobId }
    if (-not $commitIndices.ContainsKey($node.sha) -and $isFileChange) {
        $metadata = (Invoke-GitText -GitArguments @('-C', $repoRoot, 'show', '-s', '--format=%an%x09%ae%x09%at%x09%s', $node.sha)).TrimEnd("`r", "`n") -split "`t", 4
        $author = if ($metadata.Count -gt 0 -and $metadata[0]) { $metadata[0] } else { '(unknown)' }
        $authorMail = if ($metadata.Count -gt 1) { $metadata[1] } else { $null }
        $authorTime = if ($metadata.Count -gt 2) { [long]$metadata[2] } else { 0L }
        $summary = if ($metadata.Count -gt 3) { $metadata[3] } else { '' }
        $commitIndices[$node.sha] = $commitBySha.Count
        $commitBySha[$node.sha] = [ordered]@{ sha = $node.sha; author = $author; authorMail = $authorMail; authorTime = $authorTime; summary = $summary; addedLines = 0; removedLines = 0; removalOnly = $false }
        $authorKey = if ($authorMail) { $authorMail } else { $author }
        if (-not $userByKey.Contains($authorKey)) {
            $userIndices[$authorKey] = $userByKey.Count
            $userByKey[$authorKey] = [ordered]@{ id = $userByKey.Count; name = $author; email = $authorMail }
        }
    }

    $owners = [int[]]::new($newPoints.Count)
    $newCommitIndex = if ($commitIndices.ContainsKey($node.sha)) { $commitIndices[$node.sha] } else { -1 }
    for ($pointIndex = 0; $pointIndex -lt $newPoints.Count; $pointIndex++) {
        $owners[$pointIndex] = $newCommitIndex
        foreach ($candidate in $candidateMaps) {
            $oldPointIndex = $candidate.mapping[$pointIndex]
            if ($oldPointIndex -ge 0) {
                $owners[$pointIndex] = $candidate.state.owners[$oldPointIndex]
                break
            }
        }
    }
    if ($owners -contains -1) {
        throw "Could not identify the introducing commit for every code point in revision $($node.sha) of $currentPath."
    }
    $stateByCommit[$node.sha] = [pscustomobject]@{ text = $currentText; owners = $owners }
    if ($node.sha -eq $headSha) { $headOwners = $owners }
    foreach ($parentSha in $node.parents) {
        if ($remainingChildren.ContainsKey($parentSha)) {
            $remainingChildren[$parentSha]--
            if ($remainingChildren[$parentSha] -le 0) { [void]$stateByCommit.Remove($parentSha) }
        }
    }
}

$characters = [System.Collections.Generic.List[object]]::new()
$textLines = [System.Collections.Generic.List[object]]::new()
$position = 0
$lineNumber = 1
$offset = 0

while ($position -lt $fileText.Length) {
    $lineStart = $position
    while ($position -lt $fileText.Length -and $fileText[$position] -ne "`r" -and $fileText[$position] -ne "`n") { $position++ }
    $content = $fileText.Substring($lineStart, $position - $lineStart)
    $ending = ''
    if ($position -lt $fileText.Length) {
        if ($fileText[$position] -eq "`r" -and $position + 1 -lt $fileText.Length -and $fileText[$position + 1] -eq "`n") {
            $ending = "`r`n"; $position += 2
        } else {
            $ending = [string]$fileText[$position]; $position++
        }
    }
    if ($lineNumber -gt $lineAttributions.Count) { throw 'Git blame returned fewer lines than the committed file contains.' }
    $blame = $lineAttributions[$lineNumber - 1]
    if (-not $blame.author) { $blame.author = '(unknown)' }

    if (-not $commitBySha.Contains($blame.sha)) {
        $commitIndices[$blame.sha] = $commitBySha.Count
        $commitBySha[$blame.sha] = [ordered]@{
            sha = $blame.sha
            author = $blame.author
            authorMail = $blame.authorMail
            authorTime = $blame.authorTime
            summary = $blame.summary
            addedLines = 0
            removedLines = 0
            removalOnly = $false
        }
    }
    $userKey = if ($blame.authorMail) { $blame.authorMail } else { $blame.author }
    if (-not $userByKey.Contains($userKey)) {
        $userIndices[$userKey] = $userByKey.Count
        $userByKey[$userKey] = [ordered]@{ id = $userByKey.Count; name = $blame.author; email = $blame.authorMail }
    }
    $commitIndex = $commitIndices[$blame.sha]
    $userIndex = $userIndices[$userKey]
    $lineCodePointStart = $offset

    foreach ($segment in @($content, $ending)) {
        for ($i = 0; $i -lt $segment.Length;) {
            $codePoint = [char]::ConvertToUtf32($segment, $i)
            $offset++
            $i += if ($codePoint -gt 0xFFFF) { 2 } else { 1 }
        }
    }
    $textLines.Add([ordered]@{ line = $lineNumber; start = $lineCodePointStart; count = $offset - $lineCodePointStart; commit = $commitIndex; user = $userIndex })
    $lineNumber++
}

if ($fileText.Length -eq 0 -and $lineAttributions.Count -ne 0) { throw 'Git blame returned unexpected lines for an empty file.' }
if ($lineNumber - 1 -ne $lineAttributions.Count) { throw 'Git blame line count does not match the committed file.' }

[int[]] $characterOwners = $headOwners
if ($characterOwners.Length -ne $offset) {
    throw "Character diff produced $($characterOwners.Length) attributions for $offset code points in $relativePath."
}
for ($characterIndex = 0; $characterIndex -lt $characterOwners.Length; $characterIndex++) {
    $ownerIndex = $characterOwners[$characterIndex]
    if ($characters.Count -gt 0 -and $characters[$characters.Count - 1].commit -eq $ownerIndex) {
        $characters[$characters.Count - 1].count++
    } else {
        $characters.Add([ordered]@{ start = $characterIndex; count = 1; commit = $ownerIndex })
    }
}

$result = [ordered]@{
    schemaVersion = 2
    path = $relativePath
    revision = 'HEAD'
    encoding = 'UTF-8'
    characterUnit = 'Unicode code point'
    attributionMethod = 'Unicode code point diff across file history; unchanged characters retain their prior attribution'
    diffAlgorithm = 'Myers shortest edit script with deterministic tie-breaking'
    mergeAttribution = 'Preserve a matching character from the first parent, then later parents; attribute unmatched characters to the merge commit'
    text = $fileText
    commits = @($commitBySha.Values)
    removalOnlyCommits = @($commitBySha.Values | Where-Object { $_.removalOnly })
    users = @($userByKey.Values)
    lines = @($textLines)
    provenance = @($characters)
}

if (-not $OutputPath) { $OutputPath = "$relativePath.provenance.json" }
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath, $repoRoot)
$outputDirectory = [System.IO.Path]::GetDirectoryName($outputFullPath)
[void] [System.IO.Directory]::CreateDirectory($outputDirectory)
$json = ConvertTo-Json -InputObject $result -Depth 20
[System.IO.File]::WriteAllText($outputFullPath, $json, [System.Text.UTF8Encoding]::new($false))
Write-Output $outputFullPath
