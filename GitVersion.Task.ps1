$Script:GitVersionMessagePrefix ??= "semver"
$Script:GitVersionTagPrefix ??= "v"

Add-BuildTask GitVersion @{
    Inputs  = {
        # Exclude generated source files in /obj/ folders
        Get-ChildItem $BuildRoot -Recurse -File
    }
    Outputs = {
        if ($script:BuildSystem -eq "None") {
            # Locally, we can never skip versioning, because someone could have tagged git
            $BuildRoot
        } else {
            # In the build system, run it ONCE PER BUILD PER PROJECT
            # Use a $TempRoot the build cleans
            $VersionFile = Join-Path $TempRoot -ChildPath "$GitSha.json"
            if (Test-Path $VersionFile) {
                $script:GitVersion = Get-Content $VersionFile | ConvertFrom-Json
            }
            $VersionFile
        }
    }
    Jobs    = {

        Write-Information "  (GitVersion) GitSha: $Script:GitSha"

        $VersionFile = Join-Path $TempRoot -ChildPath "$GitSha.json"
        $script:GitVersion = @{}
        foreach ($Name in $PackageNames) {

            if ($PackageNames.Count -gt 1) {
                $GitVersionMessagePrefix = ($GitVersionMessagePrefix, $Name) -join "-"
                $GitVersionTagPrefix = ($Name, $GitVersionTagPrefix) -join "-"
            }

            # Since we know the things we need to version, let's make *sure* that we version it:
            # Write-Host git commit "--ammend" "-m" "$commitMessage`n$GitVersionMessagePrefix:patch"
            # git commit --ammend -m "$commitMessage`n$GitVersionMessagePrefix:patch"

            $GitVersionYaml = if (Test-Path (Join-Path $BuildRoot GitVersion.yml)) {
                Join-Path $BuildRoot GitVersion.yml
            } else {
                Convert-Path (Join-Path $PSScriptRoot GitVersion.yml)
            }

            Write-Verbose "For ${Name}: Using GitVersion config $GitVersionYaml" -Verbose

            $LogFile = Join-Path $TempRoot -ChildPath "$GitVersionTagPrefix$GitSha.log"
            if (Test-Path $LogFile) {
                Remove-Item $LogFile
            }
            if (Test-Path $VersionFile) {
                Remove-Item $VersionFile
            }

            try {
                # We can't splat because it's 5 copies of the same parameter, so, use line-wrapping escapes:
                # Also, the no-bump-message has to stay at .* or else every commit to main will increment all components
                # Write-Host dotnet gitversion -config $GitVersionYaml -output file -outputfile $VersionFile -verbosity verbose
                <# -output file -outputfile $VersionFile 
                dotnet gitversion -verbosity diagnostic -config $GitVersionYaml `
                -overrideconfig tag-prefix="$($GitVersionTagPrefix)" `
                -overrideconfig major-version-bump-message="$($GitVersionMessagePrefix):\s*(breaking|major)" `
                -overrideconfig minor-version-bump-message="$($GitVersionMessagePrefix):\s*(feature|minor)" `
                -overrideconfig patch-version-bump-message="$($GitVersionMessagePrefix):\s*(fix|patch)" `
                -overrideconfig no-bump-message="$($GitVersionMessagePrefix):\s*(skip|none)" > $VersionFile 2> $LogFile
                #>

                <# Switch to conventional commit model #>
                dotnet gitversion -verbosity diagnostic -config $GitVersionYaml `
                    -overrideconfig tag-prefix="$($GitVersionTagPrefix)" `
                    -overrideconfig major-version-bump-message="(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([\w\s\-,/]*\))?(!:|:.*\n\n((.+\n)+\n)?BREAKING CHANGE:\s.+)\w" `
                    -overrideconfig minor-version-bump-message="(feat)(\([\w\s\-,/]*\))?:" `
                    -overrideconfig patch-version-bump-message="(fix|perf)(\([\w\s\-,/]*\))?:" `
                    -overrideconfig no-bump-message="$($GitVersionMessagePrefix):\s*(skip|none)" > $VersionFile 2> $LogFile

                if (Test-Path $LogFile) {
                    Write-Host $PSStyle.Formatting.Error ((Get-Content $LogFile) -join "`n") $PSStyle.Reset
                }

                if (!(Test-Path $VersionFile)) {
                    throw "GitVersion failed to produce a version file or a log file"
                } else {
                    $VersionContent = Get-Content $VersionFile
                    if (!$VersionContent) {
                        throw "GitVersion produced an empty version file"
                    }
                    try {
                        $Version = $VersionContent | ConvertFrom-Json
                    } catch {
                        throw "GitVersion produced an invalid version file: $VersionContent"
                    }
                }
            } catch {
                Write-Warning "GitVersion failed $($_.Exception.Message) trying with URL $GitUrl"
                dotnet gitversion -url $GitUrl -b $BranchName -c $GitSha -config $GitVersionYaml `
                    -overrideconfig tag-prefix="$($GitVersionTagPrefix)" `
                    -overrideconfig major-version-bump-message="(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([\w\s\-,/]*\))?(!:|:.*\n\n((.+\n)+\n)?BREAKING CHANGE:\s.+)\w" `
                    -overrideconfig minor-version-bump-message="(feat)(\([\w\s\-,/]*\))?:" `
                    -overrideconfig patch-version-bump-message="(fix|perf)(\([\w\s\-,/]*\))?:" `
                    -overrideconfig no-bump-message="$($GitVersionMessagePrefix):\s*(skip|none)" > $VersionFile 2> $LogFile


                if (Test-Path $LogFile) {
                    Write-Host $PSStyle.Formatting.Error ((Get-Content $LogFile) -join "`n") $PSStyle.Reset
                }

                if (!(Test-Path $VersionFile)) {
                    throw "GitVersion failed to produce a version file or a log file"
                } else {
                    $VersionContent = Get-Content $VersionFile
                    if (!$VersionContent) {
                        throw "GitVersion produced an empty version file"
                    }
                    try {
                        $Version = $VersionContent | ConvertFrom-Json
                    } catch {
                        throw "GitVersion produced an invalid version file: $VersionContent"
                    }
                }
            }

            $Version | Add-Member ScriptProperty Tag -Value { $GitVersionTagPrefix + $this.SemVer } -PassThru | Format-List | Out-Host
            $GitVersion[$Name] = $Version

            # Output for Azure DevOps
            if ($ENV:SYSTEM_COLLECTIONURI) {
                foreach ($envar in $Version.PSObject.Properties) {
                    $EnvVarName = if ($Name) {
                        @($Name, $Envar.Name) -join "."
                    } else {
                        $Envar.Name
                    }
                    Write-Host "INFO [task.setvariable variable=$EnvVarName;isOutput=true]$($envar.Value)"
                    Write-Host "##vso[task.setvariable variable=$EnvVarName;isOutput=true]$($envar.Value)"
                }
            } else {
                Write-Host "GitVersion: $($Version.InformationalVersion)"
            }
        }

        $GitVersion | ConvertTo-Json | Set-Content $VersionFile
    }
}
