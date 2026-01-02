<#
.SYNOPSIS
    Constants used throughout the Azure Security Audit module.

.DESCRIPTION
    Centralized constants for magic strings, numbers, and configuration values
    to improve maintainability and reduce duplication.
#>

# TLS Version Constants
$script:TLS_VERSIONS = @{
    TLS_1_0 = "TLS1_0"
    TLS_1_1 = "TLS1_1"
    TLS_1_2 = "TLS1_2"
    TLS_1_3 = "TLS1_3"
    MINIMUM_REQUIRED = "TLS1_2"
}

# Retry Configuration
$script:RETRY_CONFIG = @{
    MAX_RETRIES = 3
    BASE_DELAY_SECONDS = 2
}

# HTTP Status Codes
$script:HTTP_STATUS = @{
    TOO_MANY_REQUESTS = 429
    SERVICE_UNAVAILABLE = 503
    UNAUTHORIZED = 401
    FORBIDDEN = 403
}

# Severity Levels
$script:SEVERITY_LEVELS = @{
    CRITICAL = "Critical"
    HIGH = "High"
    MEDIUM = "Medium"
    LOW = "Low"
}

# Status Values
$script:STATUS_VALUES = @{
    PASS = "PASS"
    FAIL = "FAIL"
    ERROR = "ERROR"
    SKIPPED = "SKIPPED"
}

# CIS Levels
$script:CIS_LEVELS = @{
    LEVEL_1 = "L1"
    LEVEL_2 = "L2"
    NOT_APPLICABLE = "N/A"
}

# Severity Weights for Compliance Scoring
$script:SEVERITY_WEIGHTS = @{
    'Critical' = 4
    'High'     = 3
    'Medium'   = 2
    'Low'      = 1
}

# CIS Level Multipliers for Compliance Scoring
$script:LEVEL_MULTIPLIERS = @{
    'L1'  = 2.0
    'L2'  = 1.0
    'N/A' = 1.0
}

# Error Patterns for Transient Errors
$script:TRANSIENT_ERROR_PATTERNS = @(
    '429',
    'throttl',
    'TooManyRequests',
    '503',
    'ServiceUnavailable',
    'timeout',
    'network',
    'connection',
    'temporarily'
)

# Permission Error Patterns
$script:PERMISSION_ERROR_PATTERNS = @(
    'authorization',
    'permission',
    'access',
    'forbidden',
    'unauthorized',
    '403',
    '401'
)

# Export functions to access constants
function Get-TlsVersions {
    return $script:TLS_VERSIONS
}

function Get-RetryConfig {
    return $script:RETRY_CONFIG
}

function Get-HttpStatus {
    return $script:HTTP_STATUS
}

function Get-SeverityLevels {
    return $script:SEVERITY_LEVELS
}

function Get-StatusValues {
    return $script:STATUS_VALUES
}

function Get-CisLevels {
    return $script:CIS_LEVELS
}

function Get-SeverityWeights {
    return $script:SEVERITY_WEIGHTS
}

function Get-LevelMultipliers {
    return $script:LEVEL_MULTIPLIERS
}

function Get-TransientErrorPatterns {
    return $script:TRANSIENT_ERROR_PATTERNS
}

function Get-PermissionErrorPatterns {
    return $script:PERMISSION_ERROR_PATTERNS
}






