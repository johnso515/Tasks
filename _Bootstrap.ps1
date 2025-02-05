<#
    .SYNOPSIS
        Bootstrap the build environment.
    .DESCRIPTION
        This script is intended to be run from your build script.
        It will ensure that the build environment is ready to go.
        It will ensure that Invoke-Build is available.
        It will ensure that dotnet is available (even when we're not going to compile, I use it for GitVersion)
        It will ensure that GitVersion is available.
#>
[CmdletBinding()]
param(
    # When running locally, you can -Force to skip the confirmation prompts
    [switch]$Force,

    # I require dotnet, and gitversion
    # Defaults to the "7.0" channel, change it to change the minimum version
    [double]$DotNet = "7.0",

    # Path to a RequiredModules.psd1
    # If this file is present, Install-RequiredModule will be run on it.
    # NOTE: If this file is missing, we'll still install InvokeBuild, but if you have a RequiredModules.psd1, don't forget to include InvokeBuild in it!
    $RequiredModulesPath = (Join-Path $pwd "RequiredModules.psd1"),

    # Path to a .*proj file or .sln
    # If this file is present, dotnet restore will be run on it.
    $ProjectFile = (Join-Path $pwd "*.*proj"),

    # Scope for installation (of scripts and modules). Defaults to CurrentUser
    [ValidateSet("AllUsers", "CurrentUser")]
    $Scope = "CurrentUser"
)
$InformationPreference = "Continue"
$ErrorView = 'DetailedView'
$ErrorActionPreference = 'Stop'

Write-Information "Ensure dotnet version"
if (!((Get-Command dotnet -ErrorAction SilentlyContinue) -and ([semver](dotnet --version) -gt $DotNet))) {
    # Obviously this must not happen on CI environments, so make sure you have dotnet preinstalled there...
    Write-Host "This script can call dotnet-install to install a local copy of dotnet $DotNet -- if you'd rather install it yourself, answer no:"
    if (!$IsLinux -and !$IsMacOS) {
        Invoke-WebRequest https://dot.net/v1/dotnet-install.ps1 -OutFile bootstrap-dotnet-install.ps1
        .\bootstrap-dotnet-install.ps1 -Channel $DotNet -InstallDir $HOME\.dotnet
    } else {
        Invoke-WebRequest https://dot.net/v1/dotnet-install.sh -OutFile bootstrap-dotnet-install.sh
        chmod +x bootstrap-dotnet-install.sh
        ./bootstrap-dotnet-install.sh --channel $DotNet --install-dir $HOME/.dotnet
    }
    if (!((Get-Command dotnet -ErrorAction SilentlyContinue) -and ([semver](dotnet --version) -gt $DotNet))) {
        throw "Unable to find dotnet $DotNet or later"
    }
}

if (Test-Path $ProjectFile) {
    Write-Information "Ensure dotnet package dependencies"
    split-path $ProjectFile -Parent | push-location
    dotnet restore $ProjectFile --ucr
}

# If there is a dotnet-tools.json file, restore the tools
if (Join-Path $pwd .config dotnet-tools.json | Test-Path) {
    Write-Information "Restore dotnet tools"
    if (Test-Path $ToolsFile) {
        dotnet tool restore --tool-manifest $ToolsFile
    }
}

# Regardless of whether you have a dotnet-tools.json file, we need gitversion global tool
# dotnet 8+ can "list" tool names, but this old syntax still works:
if (!(dotnet tool list -g | Select-String "gitversion.tool")) {
    Write-Information "Ensure GitVersion.tool"
    # We need gitversion 5.x (the new 6.x version will not support SemVer 1 that PowerShell still uses)
    dotnet tool update gitversion.tool --version 5.* --global
}

if (Test-Path $HOME/.dotnet/tools) {
    Write-Information "Ensure dotnet global tools in PATH"
    # TODO: implement semi-permanent PATH modification for github and azure
    $ENV:PATH += ([IO.Path]::PathSeparator) + (Convert-Path $HOME/.dotnet/tools)
}

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Write-Information "Ensure Install-RequiredModule"
if (!($InstallRequiredModule = Get-Command Install-RequiredModule -ErrorAction SilentlyContinue)) {
    # This should install in the user's script folder (wherever that is). Passthru will tell us where.
    $Script = Install-Script Install-RequiredModule -NoPathUpdate -Force -PassThru -Scope $Scope

    # TODO: implement semi-permanent PATH modification for github and azure
    $ENV:PATH += ([IO.Path]::PathSeparator) + (Convert-Path $Script.InstalledLocation)

    $InstallRequiredModule = Join-Path $Script.InstalledLocation "Install-RequiredModule.ps1"
    # Set-Alias -Scope Global Install-RequiredModule $InstallRequiredModule
}

if (Test-Path $RequiredModulesPath) {
    Write-Information "Ensure Required Modules"
    & $InstallRequiredModule $RequiredModulesPath -Scope $Scope -Confirm:$false
} else {
    Write-Information "Ensure InvokeBuild"
    # The default required modules is just InvokeBuild
    & $InstallRequiredModule @{ InvokeBuild = "5.*" } -Scope $Scope -Confirm:$false
}

if ($IRM_InstallErrors) {
    foreach ($installErr in @($IRM_InstallErrors)) {
        Write-Warning "ERROR: $installErr"
        Write-Warning "STACKTRACE: $($installErr.ScriptStackTrace)"
    }
}