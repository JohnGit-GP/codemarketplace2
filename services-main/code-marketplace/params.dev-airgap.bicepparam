using '../../shared/main.bicep'

// ══════════════════════════════════════════════════════════════
// code-marketplace — Gov Cloud air-gap dev
// ══════════════════════════════════════════════════════════════
// Stateless gateway. State (.vsix files) lives in Artifactory's
// generic-local repo, not in Azure resources. No Bicep-managed
// infra required for this service.
// ══════════════════════════════════════════════════════════════

param serviceName = 'code-marketplace'
param environment = 'dev'
param location = 'usgovvirginia'

// ── Existing Infrastructure (overridden by deploy.sh from azure.env) ──
param aksClusterName = 'placeholder'
param aksClusterResourceGroup = 'placeholder'
param vnetName = 'placeholder'
param vnetResourceGroup = 'placeholder'
param privateEndpointSubnetName = 'placeholder'
param acrName = 'placeholder'
param acrResourceGroup = 'placeholder'

// ── Feature Flags — none required ──
param deployPostgresql = false
param deployStorageAccount = false
param deployKeyVault = false
param deployPrivateEndpoints = false